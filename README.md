# Frontier Agent Test - DockerCoins

DevOps Agent 기능 검증을 위한 테스트 환경.  
EKS 클러스터에 장애 주입 대상 앱(DockerCoins) + Private GitLab CE를 배포하여 Agent의 RCA, 코드 분석, 시나리오 실행을 테스트한다.

---

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│  AWS Account (Source)              Region: us-east-1                 │
│                                                                     │
│  VPC: ${PROJECT_NAME}-vpc  (default: 10.0.0.0/16)                   │
│  ├── Public Subnet 1:   ${VpcCidrPrefix}.1.0/24   (AZ-a) ── IGW    │
│  ├── Public Subnet 2:   ${VpcCidrPrefix}.2.0/24   (AZ-b) ── IGW    │
│  ├── Private Subnet 1:  ${VpcCidrPrefix}.11.0/24  (AZ-a) ── NAT    │
│  ├── Private Subnet 2:  ${VpcCidrPrefix}.12.0/24  (AZ-b) ── NAT    │
│  ├── Database Subnet 1: ${VpcCidrPrefix}.21.0/24  (AZ-a)           │
│  └── Database Subnet 2: ${VpcCidrPrefix}.22.0/24  (AZ-b)           │
│                                                                     │
│  EKS Cluster: ${PROJECT_NAME}-cluster                               │
│  ├── Node Group: t3.medium / t3.large (Private Subnets)             │
│  ├── K8s Service CIDR: 172.20.0.0/16                                │
│  └── Namespaces:                                                    │
│      ├── dockercoins ─── 장애 주입 대상 앱                            │
│      ├── gitlab ──────── Private GitLab CE (self-signed TLS)         │
│      ├── splunk ──────── Splunk + OTEL Collector                     │
│      ├── petclinic ───── 추가 테스트 앱 (Spring Boot)                 │
│      └── amazon-cloudwatch ─ CloudWatch Agent + AppSignals           │
│                                                                     │
│  RDS (PostgreSQL): Private Subnets ── PetClinic DB                  │
│  ECR: ${PROJECT_NAME}/* ── DockerCoins 이미지 저장                   │
│                                                                     │
│  Monitor Account (DevOps Agent Space 소유)                           │
│  └── Agent Space + IAM Role (aidevops.amazonaws.com)                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 네트워크 설정

| 리소스 | 기본값 | CFn Parameter |
|--------|--------|---------------|
| VPC CIDR | `10.0.0.0/16` | `VpcCidrPrefix=10.0` |
| Public Subnets | `.1.0/24`, `.2.0/24` | — |
| Private Subnets | `.11.0/24`, `.12.0/24` | — |
| Database Subnets | `.21.0/24`, `.22.0/24` | — |
| K8s Service CIDR | `172.20.0.0/16` | — |
| NAT Gateway | AZ당 1개 (2개 total) | — |
| Pod Networking | VPC CNI (aws-node) | — |

### Security Groups

| SG | 인바운드 | 용도 |
|----|---------|------|
| `${PROJECT_NAME}-alb-sg` | 0.0.0.0/0 → 80, 443 | ALB 외부 접근 |
| `${PROJECT_NAME}-eks-sg` | ALB SG → 3000, 8080; VPC → 22 | EKS 노드 |
| `${PROJECT_NAME}-database-sg` | EKS SG + Private Subnets → 5432 | RDS PostgreSQL |

---

## EKS 클러스터

| 항목 | 기본값 |
|------|--------|
| Cluster Name | `${PROJECT_NAME}-cluster` |
| K8s Version | 1.33 (CFn에서 선택 가능: 1.28~1.33) |
| Node Instance Types | t3.medium, t3.large |
| Node OS | Amazon Linux 2023 |
| Container Runtime | containerd |
| Addons | VPC CNI, CoreDNS, kube-proxy, EBS CSI |

---

## 서비스 배포

### 1. DockerCoins (장애 주입 대상)

마이크로서비스 기반 가상 암호화폐 채굴 앱.

```
worker → rng (GET /32)    → random bytes 생성
worker → hasher (POST /)  → SHA256 해시 계산
worker → redis (INCR)     → 채굴 카운터 증가
webui  → redis (GET)      → 실시간 채굴 속도 표시
```

| 서비스 | 역할 | 포트 | 이미지 |
|--------|------|------|--------|
| rng | 랜덤 바이트 생성 | 80 | `${ECR}/rng` |
| hasher | SHA256 해시 계산 | 80 | `${ECR}/hasher` |
| worker | 채굴 루프 | - | `${ECR}/worker` |
| webui | 실시간 대시보드 | 80 (LB) | `${ECR}/webui` |
| redis | 카운터 저장소 | 6379 | `redis:7-alpine` |

**배포:**
```bash
kubectl apply -k infrastructure/kubernetes/base/dockercoins/
# 또는 overlay 사용:
kubectl apply -k infrastructure/kubernetes/overlays/member1-acc/dockercoins/
```

### 2. GitLab CE (Private 코드 저장소)

Agent Space 데이터소스로 연결하여 코드 분석에 활용.

| 항목 | 값 |
|------|-----|
| Image | `gitlab/gitlab-ce:17.0.0-ce.0` |
| External URL | `https://gitlab.gitlab.svc.cluster.local` |
| TLS | Self-signed (initContainer에서 openssl 생성) |
| Service Type | LoadBalancer (Internal NLB, TCP 443) |
| Root Password | `PLACEHOLDER_PASSWORD` |
| Storage | PVC 10Gi (data) + 1Gi (config), StorageClass: gp2 |
| Resources | 500m~2 CPU, 2~4Gi Memory |
| Prometheus | disabled |
| Grafana/Alertmanager | disabled |

**배포:**
```bash
kubectl apply -k infrastructure/kubernetes/base/gitlab/
```

### 3. Splunk (로그 수집)

```bash
kubectl apply -k infrastructure/kubernetes/base/splunk/
```

### 4. PetClinic (Spring Boot 추가 앱)

```bash
kubectl apply -k infrastructure/kubernetes/base/petclinic/
```

---

## 인프라 배포 (CloudFormation 스택)

순서대로 배포하거나 `./infrastructure/deploy.sh`로 일괄 배포.

| 순서 | 스택 | 설명 |
|------|------|------|
| 01 | vpc-foundation | VPC, Subnets, NAT, SGs |
| 02 | eks-platform | EKS Cluster, Node Group, ECR, LB Controller |
| 03 | rds-database | PostgreSQL (PetClinic용) |
| 04 | devops-agent | Agent Space, IAM Role |
| 05 | transaction-search | X-Ray / Transaction Search |
| 06 | cloudwatch-alarms | CloudWatch 알람 |
| 07 | fis-experiments | FIS 장애 주입 실험 |
| 08 | github-actions | GitHub OIDC + Actions Role |
| 09 | route53-private-zone | Private DNS (gitlab.internal 등) |
| 10 | security-agent-role | Security Agent IAM |
| 11 | privatelink-provider | PrivateLink VPC Endpoint Service |
| 12 | privatelink-consumer | PrivateLink Consumer |
| 13 | devops-agent-secondary-role | Cross-account Agent Role |
| 14 | dashboard-cross-account-access | Dashboard용 Cross-account |
| 15 | devops-agent-source-account | Source Account Association |
| 16 | agent-space-association | Agent Space Data Source 연결 |
| 17 | m2-ebs-csi-driver | EBS CSI Driver (GitLab PVC용) |

---

## 빠른 시작

### 1. 환경 설정

```bash
cp config/member1-acc.env.example config/member1-acc.env
# AWS_ACCOUNT_ID, AWS_PROFILE, AWS_REGION 등 편집
```

### 2. 전체 배포 (인프라 + 앱)

```bash
./infrastructure/deploy.sh
```

### 3. DockerCoins만 배포

```bash
./infrastructure/deploy-dockercoins.sh
```

### 4. 로컬 개발 (Docker Compose)

```bash
cd services/dockercoins
docker-compose up --build
# webui: http://localhost:8000
# rng:   http://localhost:8001
# hasher: http://localhost:8002
```

---

## 디렉토리 구조

```
.
├── config/                          # 환경별 설정 (.env)
│   ├── member1-acc.env.example
│   └── member2-acc.env.example
├── infrastructure/
│   ├── cloudformation/              # AWS CFn 스택 (01~17)
│   ├── kubernetes/
│   │   ├── base/
│   │   │   ├── dockercoins/         # DockerCoins K8s manifests
│   │   │   ├── gitlab/              # GitLab CE K8s manifests
│   │   │   ├── splunk/              # Splunk + OTEL
│   │   │   ├── petclinic/           # PetClinic manifests
│   │   │   └── overview/            # Overview dashboard
│   │   ├── overlays/                # Kustomize overlays (계정별)
│   │   │   ├── member1-acc/
│   │   │   └── member2-acc/
│   │   ├── build/                   # Kaniko 이미지 빌드
│   │   └── dashboard/               # Simulator dashboard
│   └── *.sh                         # 배포 스크립트
├── services/
│   └── dockercoins/                 # 앱 소스 (hasher, rng, webui, worker)
├── scripts/                         # 유틸리티 (build-push, otel-diag 등)
└── docker-compose.yml               # 로컬 개발용
```

---

## 필요 리소스 요약

| 리소스 | 최소 사양 | 비고 |
|--------|-----------|------|
| EKS Nodes | 3x t3.medium + 1x t3.large | GitLab CE 4Gi 요구 |
| VPC | /16 CIDR, 2 AZ, 6 Subnets | NAT Gateway 2개 |
| ECR | `${PROJECT_NAME}/*` repos | hasher, rng, webui, worker |
| EBS | gp2 11Gi | GitLab PVC (data 10Gi + config 1Gi) |
| RDS | db.t3.micro PostgreSQL | PetClinic용 |
| NLB | Internal | GitLab HTTPS 접근 |
| ACM Certificate | 선택 | ALB HTTPS 사용 시 |
| NAT Gateway | 2개 | Private Subnet → Internet |

---

## 기본 설정 값

| 설정 | 기본값 |
|------|--------|
| VPC CIDR Prefix | `10.0` |
| K8s Version | 1.33 |
| GitLab Image | `gitlab/gitlab-ce:17.0.0-ce.0` |
| GitLab Root PW | `PLACEHOLDER_PASSWORD` |
| GitLab TLS | Self-signed (initContainer 생성) |
| GitLab Storage | gp2, 10Gi data + 1Gi config |
| Redis | In-cluster (redis:7-alpine, 비영속) |
| Worker Replicas | 설정 가능 (overlay) |
| OTEL Instrumentation | DockerCoins namespace 활성화 |
| CloudWatch AppSignals | 활성화 |

---

## Multi-Account 지원

`config/member2-acc.env.example` + `infrastructure/kubernetes/overlays/member2-acc/`으로 두 번째 계정에도 동일 환경 배포 가능.

| 계정 | 역할 |
|------|------|
| Member 1 (Source) | DockerCoins + GitLab 운영, 모니터링 데이터 생성 |
| Member 2 (Source) | 추가 Splunk 환경 |
| Monitor Account | DevOps Agent Space 소유, Cross-account 접근 |
