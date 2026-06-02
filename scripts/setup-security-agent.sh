#!/bin/bash
# =============================================================================
# AWS Security Agent 셋업 스크립트
# CloudFormation 미지원 리소스를 API로 생성/구성
#
# 사전 요구사항:
#   - AWS CLI 2.34.21+ (PATH="/usr/local/bin:$PATH")
#   - config/<profile>.env 설정 완료
#   - CloudFormation 스택 배포 완료 (01~10번)
#   - EKS 클러스터 및 DockerCoins 앱 배포 완료
# =============================================================================

set -euo pipefail

# ---- 설정 (config에서 로드) ----
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
PROFILE="$AWS_PROFILE"
REGION="$AWS_REGION"
AWS="PATH=/usr/local/bin:\$PATH aws"

GITHUB_REPO_NAME="$GITHUB_REPO"
GITHUB_REPO_OWNER="$GITHUB_ORG"

DOMAIN="webui.${DOMAIN}"
AGENT_SPACE_NAME="security-agent-test-v2"

# Lookup infrastructure IDs from CloudFormation outputs
cfn_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text --profile "$PROFILE" --region "$REGION"
}
VPC_ID=$(cfn_output "${PROJECT_NAME}-vpc-foundation" "VpcId")
SUBNET_1=$(cfn_output "${PROJECT_NAME}-vpc-foundation" "PrivateSubnet1Id")
SUBNET_2=$(cfn_output "${PROJECT_NAME}-vpc-foundation" "PrivateSubnet2Id")
SG_SECURITY_AGENT=$(cfn_output "${PROJECT_NAME}-security-agent" "SecurityAgentSecurityGroupId")
SG_EKS_CLUSTER=$(cfn_output "${PROJECT_NAME}-eks-platform" "ClusterSecurityGroupId")
SG_EKS_WORKER=$(cfn_output "${PROJECT_NAME}-eks-platform" "NodeSecurityGroupId")
SG_ALB=$(cfn_output "${PROJECT_NAME}-eks-platform" "AlbSecurityGroupId" 2>/dev/null || echo "")
SG_WEBUI_ELB=$(cfn_output "${PROJECT_NAME}-eks-platform" "WebUIElbSecurityGroupId" 2>/dev/null || echo "")

# ---- 함수 ----
log() { echo "[$(date '+%H:%M:%S')] $*"; }

get_service_role() {
  aws iam list-roles --profile "$PROFILE" \
    --query 'Roles[?contains(RoleName,`security-testing`)].Arn | [0]' \
    --output text 2>/dev/null
}

# ---- 메인 ----
log "=== AWS Security Agent Setup ==="
log "Account: $AWS_ACCOUNT_ID ($PROFILE)"
log "Region: $REGION"

SERVICE_ROLE=$(get_service_role)
log "Service Role: $SERVICE_ROLE"

# 1. Target Domain 생성
log ""
log "--- Step 1: Target Domain ---"
EXISTING_TD=$(aws securityagent list-target-domains \
  --profile "$PROFILE" --region "$REGION" \
  --query "targetDomainSummaries[?domainName=='$DOMAIN'].targetDomainId | [0]" \
  --output text 2>/dev/null)

if [ "$EXISTING_TD" != "None" ] && [ -n "$EXISTING_TD" ]; then
  log "Target domain already exists: $EXISTING_TD"
  TARGET_DOMAIN_ID="$EXISTING_TD"
else
  log "Creating target domain: $DOMAIN"
  TD_RESULT=$(aws securityagent create-target-domain \
    --target-domain-name "$DOMAIN" \
    --verification-method DNS_TXT \
    --profile "$PROFILE" --region "$REGION" 2>&1)
  TARGET_DOMAIN_ID=$(echo "$TD_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['targetDomainId'])")
  log "Created: $TARGET_DOMAIN_ID"

  # DNS TXT 토큰 출력
  TOKEN=$(echo "$TD_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['verificationDetails']['dnsTxt']['token'])")
  log "DNS TXT verification token: $TOKEN"
  log ">> Route53에 TXT 레코드 추가 필요: _aws_securityagent-challenge.$DOMAIN"

  # Verify
  aws securityagent verify-target-domain \
    --target-domain-id "$TARGET_DOMAIN_ID" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  log "Verification status: UNREACHABLE (Private domain - 정상)"
fi

# 2. Agent Space 생성
log ""
log "--- Step 2: Agent Space ---"
EXISTING_AS=$(aws securityagent list-agent-spaces \
  --profile "$PROFILE" --region "$REGION" \
  --query "agentSpaceSummaries[?name=='$AGENT_SPACE_NAME'].agentSpaceId | [0]" \
  --output text 2>/dev/null)

if [ "$EXISTING_AS" != "None" ] && [ -n "$EXISTING_AS" ]; then
  log "Agent space already exists: $EXISTING_AS"
  AGENT_SPACE_ID="$EXISTING_AS"
else
  log "Creating agent space: $AGENT_SPACE_NAME"
  AS_RESULT=$(aws securityagent create-agent-space \
    --name "$AGENT_SPACE_NAME" \
    --description "Security Agent test environment for DockerCoins pentest" \
    --aws-resources "{
      \"vpcs\": [{
        \"vpcArn\": \"$VPC_ID\",
        \"securityGroupArns\": [\"$SG_SECURITY_AGENT\",\"$SG_EKS_CLUSTER\",\"$SG_EKS_WORKER\",\"$SG_ALB\",\"$SG_WEBUI_ELB\"],
        \"subnetArns\": [\"$SUBNET_1\",\"$SUBNET_2\"]
      }],
      \"iamRoles\": [\"$SERVICE_ROLE\"]
    }" \
    --target-domain-ids "$TARGET_DOMAIN_ID" \
    --code-review-settings '{"controlsScanning":true,"generalPurposeScanning":true}' \
    --tags auto-delete=never \
    --profile "$PROFILE" --region "$REGION" 2>&1)
  AGENT_SPACE_ID=$(echo "$AS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['agentSpaceId'])")
  log "Created: $AGENT_SPACE_ID"
fi

# 3. GitHub Integration 연결
log ""
log "--- Step 3: GitHub Integration ---"
EXISTING_GH=$(aws securityagent list-integrated-resources \
  --agent-space-id "$AGENT_SPACE_ID" \
  --integration-id "$GITHUB_INTEGRATION_ID" \
  --profile "$PROFILE" --region "$REGION" \
  --query 'integratedResourceSummaries | length(@)' \
  --output text 2>/dev/null)

if [ "$EXISTING_GH" -gt 0 ] 2>/dev/null; then
  log "GitHub integration already connected"
else
  log "Connecting GitHub repo: $GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
  aws securityagent update-integrated-resources \
    --agent-space-id "$AGENT_SPACE_ID" \
    --integration-id "$GITHUB_INTEGRATION_ID" \
    --items "[{
      \"resource\":{\"githubRepository\":{\"name\":\"$GITHUB_REPO_NAME\",\"owner\":\"$GITHUB_REPO_OWNER\"}},
      \"capabilities\":{\"github\":{\"leaveComments\":true,\"remediateCode\":true}}
    }]" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  log "GitHub integration connected"
fi

# 4. 요약
log ""
log "=== Setup Complete ==="
log "Agent Space:    $AGENT_SPACE_ID"
log "Target Domain:  $TARGET_DOMAIN_ID ($DOMAIN)"
log "Service Role:   $SERVICE_ROLE"
log ""
log "Pentest 실행:"
log "  aws securityagent create-pentest \\"
log "    --agent-space-id $AGENT_SPACE_ID \\"
log "    --title \"DockerCoins-WebUI-Pentest\" \\"
log "    --assets '{\"endpoints\":[{\"uri\":\"http://$DOMAIN\"}]}' \\"
log "    --service-role \"$SERVICE_ROLE\" \\"
log "    --vpc-config '{\"vpcArn\":\"$VPC_ID\",\"securityGroupArns\":[\"$SG_SECURITY_AGENT\"],\"subnetArns\":[\"$SUBNET_1\"]}' \\"
log "    --profile $PROFILE --region $REGION"
