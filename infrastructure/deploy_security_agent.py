#!/usr/bin/env python3
"""
AWS Security Agent 자동 프로비저닝 스크립트 (boto3 API)

사용법:
  python3 deploy_security_agent.py [--config path/to/config.json] [--run-pentest]

전체 흐름:
  Phase 0: 사전 검증
  Phase 1: Application (이미 있으면 스킵)
  Phase 2: GitHub Integration (OAuth 1회 필요)
  Phase 3: Target Domain + DNS 검증
  Phase 4: Agent Space (코드리뷰 설정 포함)
  Phase 5: Pentest 설정
  Phase 6: 첫 Pentest 실행 (선택)
  Phase 7: 결과 출력
"""
import argparse
import json
import sys
import time
from pathlib import Path

import boto3
from botocore.config import Config

SCRIPT_DIR = Path(__file__).parent
DEFAULT_CONFIG = SCRIPT_DIR / "security-agent-config.json"


def load_config(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def err(msg: str):
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


class SecurityAgentDeployer:
    def __init__(self, cfg: dict, run_pentest: bool = False):
        self.cfg = cfg
        self.run_pentest = run_pentest
        self.profile = cfg["aws_profile"]
        self.region = cfg["aws_region"]

        session = boto3.Session(profile_name=self.profile, region_name=self.region)
        self.sa = session.client("securityagent", config=Config(read_timeout=120, connect_timeout=10))
        self.r53 = session.client("route53")
        self.sts = session.client("sts")

        self.state_file = SCRIPT_DIR / f".security-agent-state-{cfg['project_name']}.json"
        self.state = self._load_state()

        # 결과 저장용
        self.application_id = None
        self.integration_id = None
        self.target_domain_ids = []
        self.agent_space_id = None
        self.pentest_id = None

    def _load_state(self) -> dict:
        if self.state_file.exists():
            with open(self.state_file) as f:
                return json.load(f)
        return {}

    def _save_state(self):
        with open(self.state_file, "w") as f:
            json.dump(self.state, f, indent=2)

    # =========================================================================
    # Phase 0: 사전 검증
    # =========================================================================
    def phase0_preflight(self):
        log("=== Phase 0: 사전 검증 ===")

        identity = self.sts.get_caller_identity()
        log(f"  AWS Account: {identity['Account']} (Profile: {self.profile})")

        # securityagent 호출 테스트
        try:
            self.sa.list_applications()
            log("  securityagent API: OK")
        except Exception as e:
            err(f"securityagent API 호출 실패: {e}")

    # =========================================================================
    # Phase 1: Application
    # =========================================================================
    def phase1_application(self):
        log("=== Phase 1: Application ===")

        resp = self.sa.list_applications()
        apps = resp.get("applicationSummaries", [])

        if apps:
            self.application_id = apps[0]["applicationId"]
            log(f"  기존 Application 사용: {self.application_id}")
        else:
            role_arn = self.cfg["iam"]["service_role_arn"]
            resp = self.sa.create_application(roleArn=role_arn)
            self.application_id = resp["applicationId"]
            log(f"  Application 생성 완료: {self.application_id}")

        self.state["application_id"] = self.application_id
        self._save_state()

    # =========================================================================
    # Phase 2: GitHub Integration
    # =========================================================================
    def phase2_github_integration(self):
        log("=== Phase 2: GitHub Integration ===")

        resp = self.sa.list_integrations()
        integrations = resp.get("integrationSummaries", [])

        if integrations:
            self.integration_id = integrations[0]["integrationId"]
            log(f"  기존 Integration 사용: {self.integration_id}")
            self.state["integration_id"] = self.integration_id
            self._save_state()
            return

        # OAuth 흐름
        log("  GitHub OAuth 등록 시작...")
        reg_resp = self.sa.initiate_provider_registration(provider="GITHUB")
        redirect_url = reg_resp["redirectTo"]
        csrf_state = reg_resp["csrfState"]

        print()
        print("=" * 60)
        print(" GitHub 인증 필요")
        print("=" * 60)
        print()
        print(" 1. 아래 URL을 브라우저에서 여세요:")
        print()
        print(f"    {redirect_url}")
        print()
        print(" 2. GitHub에서 'Authorize' 클릭")
        print(" 3. 리다이렉트된 URL에서 'code=' 파라미터 값을 복사하세요")
        print("    (URL 형태: https://...?code=XXXXX&state=...)")
        print()
        print("=" * 60)
        print()

        oauth_code = input("GitHub OAuth code를 입력하세요: ").strip()
        if not oauth_code:
            err("OAuth code가 비어있습니다.")

        github_cfg = self.cfg["github"]
        display_name = github_cfg.get("integration_display_name", f"{self.cfg['project_name']}-github")
        org_name = github_cfg.get("org", "")

        log("  Integration 생성 중...")
        provider_input = {"github": {"code": oauth_code, "state": csrf_state}}
        if org_name:
            provider_input["github"]["organizationName"] = org_name

        resp = self.sa.create_integration(
            provider="GITHUB",
            integrationDisplayName=display_name,
            input=provider_input,
        )
        self.integration_id = resp["integrationId"]
        log(f"  GitHub Integration 생성 완료: {self.integration_id}")

        self.state["integration_id"] = self.integration_id
        self._save_state()

    # =========================================================================
    # Phase 3: Target Domains (다중 targets 지원)
    # =========================================================================
    def phase3_target_domains(self):
        log("=== Phase 3: Target Domains ===")

        targets = self.cfg.get("targets", [])
        if not targets:
            # 단일 target 하위 호환
            targets = [self.cfg["target"]]

        existing_resp = self.sa.list_target_domains()
        existing_domains = {
            td["domainName"]: td for td in existing_resp.get("targetDomainSummaries", [])
        }

        for target_cfg in targets:
            domain = target_cfg["domain"]
            td_id = self._ensure_target_domain(target_cfg, existing_domains)
            self.target_domain_ids.append(td_id)

            # Route53 Alias record 등록 (NLB가 설정된 경우)
            nlb_dns = target_cfg.get("nlb_dns")
            if nlb_dns:
                self._ensure_route53_alias(target_cfg, nlb_dns)

        self.state["target_domain_ids"] = self.target_domain_ids
        self._save_state()

    def _ensure_target_domain(self, target_cfg: dict, existing_domains: dict) -> str:
        domain = target_cfg["domain"]

        if domain in existing_domains:
            td = existing_domains[domain]
            td_id = td["targetDomainId"]
            log(f"  [{domain}] 기존 Target Domain 사용: {td_id} (status: {td['verificationStatus']})")
            return td_id

        verification_method = target_cfg.get("verification_method", "DNS_TXT")
        log(f"  [{domain}] Target Domain 생성 (method: {verification_method})")

        resp = self.sa.create_target_domain(
            targetDomainName=domain,
            verificationMethod=verification_method,
        )
        td_id = resp["targetDomainId"]
        log(f"  [{domain}] Target Domain 생성 완료: {td_id}")

        if verification_method == "DNS_TXT":
            dns_txt = resp["verificationDetails"]["dnsTxt"]
            token = dns_txt["token"]
            record_name = dns_txt["dnsRecordName"]
            zone_id = target_cfg["route53_zone_id"]

            log(f"  [{domain}] Route53 TXT 레코드 추가: {record_name}")
            self.r53.change_resource_record_sets(
                HostedZoneId=zone_id,
                ChangeBatch={
                    "Changes": [{
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": record_name,
                            "Type": "TXT",
                            "TTL": 300,
                            "ResourceRecords": [{"Value": f'"{token}"'}],
                        },
                    }]
                },
            )

        is_private = target_cfg.get("private_dns", False)
        if is_private:
            log(f"  [{domain}] Private DNS — 검증 UNREACHABLE 예상 (VPC config으로 동작)")
            try:
                self.sa.verify_target_domain(targetDomainId=td_id)
            except Exception:
                pass
        else:
            log(f"  [{domain}] 도메인 검증 대기 (30초)...")
            time.sleep(30)
            verify_resp = self.sa.verify_target_domain(targetDomainId=td_id)
            log(f"  [{domain}] 검증 상태: {verify_resp.get('status', 'UNKNOWN')}")

        return td_id

    def _ensure_route53_alias(self, target_cfg: dict, nlb_dns: str):
        """Route53 Alias A record로 NLB를 가리킨다 (private zone에서 CNAME은 동작 안 함)."""
        domain = target_cfg["domain"]
        zone_id = target_cfg["route53_zone_id"]

        nlb_hosted_zone_id = target_cfg.get("nlb_hosted_zone_id")
        if not nlb_hosted_zone_id:
            nlb_hosted_zone_id = self._discover_nlb_hosted_zone(nlb_dns)

        log(f"  [{domain}] Route53 Alias A → {nlb_dns} (zone: {nlb_hosted_zone_id})")
        self.r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={
                "Changes": [{
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": domain,
                        "Type": "A",
                        "AliasTarget": {
                            "HostedZoneId": nlb_hosted_zone_id,
                            "DNSName": nlb_dns.rstrip(".") + ".",
                            "EvaluateTargetHealth": True,
                        },
                    },
                }]
            },
        )

    def _discover_nlb_hosted_zone(self, nlb_dns: str) -> str:
        """NLB DNS로부터 CanonicalHostedZoneId를 조회."""
        session = boto3.Session(profile_name=self.profile, region_name=self.region)
        elb = session.client("elbv2")
        paginator = elb.get_paginator("describe_load_balancers")
        for page in paginator.paginate():
            for lb in page["LoadBalancers"]:
                if lb["DNSName"].rstrip(".") == nlb_dns.rstrip("."):
                    return lb["CanonicalHostedZoneId"]
        err(f"NLB not found for DNS: {nlb_dns}. 수동으로 nlb_hosted_zone_id를 config에 지정하세요.")

    # =========================================================================
    # Phase 4: Agent Space
    # =========================================================================
    def phase4_agent_space(self):
        log("=== Phase 4: Agent Space ===")

        space_cfg = self.cfg["agent_space"]
        space_name = space_cfg["name"]

        # 기존 확인
        resp = self.sa.list_agent_spaces()
        for s in resp.get("agentSpaceSummaries", []):
            if s["name"] == space_name:
                self.agent_space_id = s["agentSpaceId"]
                log(f"  기존 Agent Space 사용: {self.agent_space_id}")
                self.state["agent_space_id"] = self.agent_space_id
                self._save_state()
                return

        vpc_cfg = self.cfg["vpc"]
        iam_cfg = self.cfg["iam"]
        code_review = space_cfg.get("code_review", {})

        log(f"  Agent Space 생성: {space_name}")
        resp = self.sa.create_agent_space(
            name=space_name,
            description=space_cfg.get("description", ""),
            codeReviewSettings={
                "controlsScanning": code_review.get("controls_scanning", True),
                "generalPurposeScanning": code_review.get("general_purpose_scanning", True),
            },
            awsResources={
                "vpcs": [{
                    "vpcArn": vpc_cfg["vpc_arn"],
                    "subnetArns": vpc_cfg["subnet_arns"],
                    "securityGroupArns": vpc_cfg["security_group_arns"],
                }],
                "iamRoles": [iam_cfg["service_role_arn"]],
            },
            targetDomainIds=self.target_domain_ids,
        )
        self.agent_space_id = resp["agentSpaceId"]
        log(f"  Agent Space 생성 완료: {self.agent_space_id}")

        self.state["agent_space_id"] = self.agent_space_id
        self._save_state()

    # =========================================================================
    # Phase 4.5: 리포 SAST 등록
    # =========================================================================
    def phase4_5_register_repo(self):
        log("=== Phase 4.5: GitHub 리포 SAST 등록 ===")

        if not self.integration_id:
            log("  [스킵] Integration 없음")
            return

        repo_name = self.cfg["github"]["repo"]
        repo_owner = self.cfg["github"]["org"]

        try:
            resp = self.sa.list_integrated_resources(
                agentSpaceId=self.agent_space_id,
                integrationId=self.integration_id,
            )
            existing = [
                r["resource"]["githubRepository"]["name"]
                for r in resp.get("integratedResourceSummaries", [])
                if "githubRepository" in r.get("resource", {})
            ]
        except Exception as e:
            log(f"  [경고] 리소스 목록 조회 실패: {e}")
            existing = []

        if repo_name in existing:
            log(f"  리포 이미 등록됨: {repo_owner}/{repo_name}")
            return

        log(f"  리포 등록 중: {repo_owner}/{repo_name}")
        self.sa.update_integrated_resources(
            agentSpaceId=self.agent_space_id,
            integrationId=self.integration_id,
            items=[{
                "resource": {"githubRepository": {"name": repo_name, "owner": repo_owner}},
                "capabilities": {"github": {"leaveComments": True, "remediateCode": True}},
            }],
        )
        log(f"  리포 SAST 등록 완료: {repo_owner}/{repo_name} (자동 코드 리뷰 + 자동 수정 활성화)")

    # =========================================================================
    # Phase 5: Pentest 설정
    # =========================================================================
    def phase5_pentest(self):
        log("=== Phase 5: Pentest 설정 ===")

        # 기존 확인
        resp = self.sa.list_pentests(agentSpaceId=self.agent_space_id)
        pentests = resp.get("pentestSummaries", [])
        if pentests:
            self.pentest_id = pentests[0]["pentestId"]
            log(f"  기존 Pentest 설정 사용: {self.pentest_id}")
            self.state["pentest_id"] = self.pentest_id
            self._save_state()
            return

        pentest_cfg = self.cfg["pentest"]
        targets = self.cfg.get("targets", [self.cfg.get("target", {})])
        vpc_cfg = self.cfg["vpc"]
        iam_cfg = self.cfg["iam"]

        # 모든 targets의 endpoint를 pentest 대상에 추가
        endpoints = [{"uri": t["endpoint"]} for t in targets if t.get("endpoint")]
        assets = {"endpoints": endpoints}
        if self.integration_id:
            try:
                int_resp = self.sa.list_integrated_resources(
                    integrationId=self.integration_id,
                    agentSpaceId=self.agent_space_id,
                )
                resources = int_resp.get("integratedResources", [])
                if resources:
                    provider_resource_id = resources[0]["providerResourceId"]
                    assets["integratedRepositories"] = [{
                        "integrationId": self.integration_id,
                        "providerResourceId": provider_resource_id,
                    }]
                    log(f"  GitHub repo 연결: {provider_resource_id}")
            except Exception as e:
                log(f"  [경고] GitHub repo 조회 실패: {e}")

        kwargs = {
            "agentSpaceId": self.agent_space_id,
            "title": pentest_cfg["title"],
            "serviceRole": iam_cfg["service_role_arn"],
            "assets": assets,
            "codeRemediationStrategy": pentest_cfg.get("code_remediation_strategy", "AUTOMATIC"),
            "vpcConfig": {
                "vpcArn": vpc_cfg["vpc_arn"],
                "subnetArns": vpc_cfg["subnet_arns"][:1],
                "securityGroupArns": vpc_cfg["security_group_arns"][:1],
            },
        }

        exclude = pentest_cfg.get("exclude_risk_types", [])
        if exclude:
            kwargs["excludeRiskTypes"] = exclude

        log_group = pentest_cfg.get("log_group")
        if log_group:
            kwargs["logConfig"] = {"logGroup": log_group}

        log(f"  Pentest 생성: {pentest_cfg['title']}")
        resp = self.sa.create_pentest(**kwargs)
        self.pentest_id = resp["pentestId"]
        log(f"  Pentest 생성 완료: {self.pentest_id}")

        self.state["pentest_id"] = self.pentest_id
        self._save_state()

    # =========================================================================
    # Phase 6: 첫 Pentest 실행 (선택)
    # =========================================================================
    def phase6_run_pentest(self):
        should_run = self.run_pentest or self.cfg.get("options", {}).get("run_first_pentest", False)
        if not should_run:
            return

        log("=== Phase 6: Pentest 실행 ===")

        resp = self.sa.start_pentest_job(
            agentSpaceId=self.agent_space_id,
            pentestId=self.pentest_id,
        )
        job_id = resp["pentestJobId"]
        status = resp["status"]
        log(f"  Pentest Job 시작: {job_id} (status: {status})")

        self.state["last_pentest_job_id"] = job_id
        self._save_state()

        # 폴링 (최대 30분)
        max_wait = 1800
        elapsed = 0
        interval = 30

        while status == "IN_PROGRESS" and elapsed < max_wait:
            time.sleep(interval)
            elapsed += interval
            try:
                jobs_resp = self.sa.batch_get_pentest_jobs(
                    agentSpaceId=self.agent_space_id,
                    pentestJobIds=[job_id],
                )
                status = jobs_resp["pentestJobs"][0]["status"]
            except Exception:
                status = "UNKNOWN"
            log(f"  [{elapsed // 60}분] 상태: {status}")

        if status == "COMPLETED":
            log("  Pentest 완료!")
            findings_resp = self.sa.list_findings(
                agentSpaceId=self.agent_space_id,
                pentestJobId=job_id,
            )
            count = len(findings_resp.get("findingsSummaries", []))
            log(f"  발견된 취약점: {count}건")
        else:
            log(f"  Pentest 상태: {status}")

    # =========================================================================
    # Phase 7: 결과 출력
    # =========================================================================
    def phase7_summary(self):
        log("=== Phase 7: 결과 요약 ===")
        print()
        print("=" * 60)
        print(" AWS Security Agent 프로비저닝 완료")
        print("=" * 60)
        print()
        print(f" Application ID:  {self.application_id}")
        print(f" Integration ID:  {self.integration_id}")
        print(f" Target Domains:  {self.target_domain_ids}")
        print(f" Agent Space ID:  {self.agent_space_id}")
        print(f" Pentest ID:      {self.pentest_id}")
        print()
        print(f" State 파일: {self.state_file}")
        print()
        print("-" * 60)
        print(" 오버뷰앱 config.yaml 추가 snippet:")
        print("-" * 60)
        print()
        print("security_agent:")
        print(f'  agent_space_id: "{self.agent_space_id}"')
        print(f'  application_id: "{self.application_id}"')
        print(f'  pentest_id: "{self.pentest_id}"')
        print(f'  integration_id: "{self.integration_id}"')
        print(f'  target_domain_ids: {self.target_domain_ids}')
        print()
        print("=" * 60)
        print()
        print(" 다음 단계:")
        print("   - Pentest 실행: python3 deploy_security_agent.py --run-pentest")
        print(f"   - Findings 조회: aws securityagent list-findings \\")
        print(f"       --agent-space-id {self.agent_space_id} \\")
        print(f"       --pentest-job-id <JOB_ID>")
        print()

    # =========================================================================
    # Run
    # =========================================================================
    def deploy(self):
        log("AWS Security Agent 자동 프로비저닝 시작")
        print()

        self.phase0_preflight()
        self.phase1_application()
        self.phase2_github_integration()
        self.phase3_target_domains()
        self.phase4_agent_space()
        self.phase4_5_register_repo()
        self.phase5_pentest()
        self.phase6_run_pentest()
        self.phase7_summary()

        log("완료!")


def main():
    parser = argparse.ArgumentParser(description="AWS Security Agent 자동 프로비저닝")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="설정 파일 경로")
    parser.add_argument("--run-pentest", action="store_true", help="프로비저닝 후 첫 Pentest 실행")
    args = parser.parse_args()

    if not args.config.exists():
        err(f"Config file not found: {args.config}")

    cfg = load_config(args.config)
    deployer = SecurityAgentDeployer(cfg, run_pentest=args.run_pentest)
    deployer.deploy()


if __name__ == "__main__":
    main()
