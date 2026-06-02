#!/bin/bash
# 범용 전체 환경 배포 스크립트
# 사용법: ./deploy.sh --profile <aws-profile> --project <project-name> [options]
#
# Unit별 선택 배포:
#   --only foundation    Foundation 인프라만 (VPC, EKS, RDS, Alarms, GitHub Actions)
#   --only agent         DevOps Agent만 (Agent Space, Transaction Search, Security Agent)
#   --only test-app      테스트 앱만 (DockerCoins 빌드 + K8s 배포)
#   --only overview      Overview App만 (빌드 + K8s 배포)
#   (미지정 시 전체 배포)

set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Parse arguments ──
AWS_REGION="us-east-1"
VPC_CIDR_PREFIX="10.0"
NODE_COUNT=3
ENABLE_SLACK=false
SLACK_BOT_TOKEN=""
SLACK_CHANNEL_ID=""
MULTI_ACCOUNT=false
PEER_PROFILE=""
PEER_PROJECT=""
PROVIDER_SERVICES=""
SKIP_INFRA=false
SKIP_BUILD=false
SKIP_K8S=false
ONLY_UNIT=""
GITHUB_REPO_NAME=""
GITHUB_REPO_ID=""
GITHUB_OWNER=""
GITHUB_OWNER_TYPE="user"
SLACK_WORKSPACE_ID=""
SLACK_WORKSPACE_NAME=""
SLACK_AGENT_CHANNEL_ID=""
SLACK_AGENT_CHANNEL_NAME=""

usage() {
    echo "Usage: $0 --profile <aws-profile> --project <project-name> [options]"
    echo ""
    echo "Required:"
    echo "  --profile    AWS CLI profile name"
    echo "  --project    Project name (used as CloudFormation ProjectName parameter)"
    echo ""
    echo "Options:"
    echo "  --region     AWS region (default: us-east-1)"
    echo "  --skip-infra Skip CloudFormation deployment"
    echo "  --skip-build Skip Docker image build/push"
    echo "  --skip-k8s   Skip K8s resource deployment"
    echo "  --only UNIT  Deploy only one unit: foundation|agent|test-app|overview"
    echo "  --vpc-cidr-prefix PREFIX  VPC CIDR first two octets (default: 10.0 → 10.0.0.0/16)"
    echo "  --nodes      Desired node count (default: 3)"
    echo "  --multi-account         Enable PrivateLink cross-account mode"
    echo "  --peer-profile PROFILE  Peer account AWS CLI profile (required with --multi-account)"
    echo "  --peer-project PROJECT  Peer account CFN ProjectName (required with --multi-account)"
    echo "  --provider-services SVC Comma-separated services this account provides (e.g. hasher)"
    echo "  --enable-slack          Enable Slack integration"
    echo "  --slack-bot-token TOKEN Slack bot token (required if --enable-slack)"
    echo "  --slack-channel-id ID   Slack channel ID (required if --enable-slack)"
    echo ""
    echo "Agent Data Sources:"
    echo "  --github-repo-name NAME  GitHub repo name (enables GitHub association)"
    echo "  --github-repo-id ID      GitHub repo numeric ID"
    echo "  --github-owner OWNER     GitHub repo owner (org or user)"
    echo "  --github-owner-type TYPE GitHub owner type: organization|user (default: user)"
    echo "  --slack-workspace-id ID  Slack workspace ID e.g. T0XXXXXXX (enables Slack association)"
    echo "  --slack-workspace-name N Slack workspace display name"
    echo "  --slack-agent-channel-id ID  Slack channel ID for agent e.g. C0XXXXXXX"
    echo "  --slack-agent-channel-name N Slack channel name (optional)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)  AWS_PROFILE="$2"; shift 2 ;;
        --project)  PROJECT_NAME="$2"; shift 2 ;;
        --region)   AWS_REGION="$2"; shift 2 ;;
        --vpc-cidr-prefix) VPC_CIDR_PREFIX="$2"; shift 2 ;;
        --skip-infra) SKIP_INFRA=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --skip-k8s)   SKIP_K8S=true; shift ;;
        --only) ONLY_UNIT="$2"; shift 2 ;;
        --nodes) NODE_COUNT="$2"; shift 2 ;;
        --multi-account) MULTI_ACCOUNT=true; shift ;;
        --peer-profile) PEER_PROFILE="$2"; shift 2 ;;
        --peer-project) PEER_PROJECT="$2"; shift 2 ;;
        --provider-services) PROVIDER_SERVICES="$2"; shift 2 ;;
        --enable-slack) ENABLE_SLACK=true; shift ;;
        --slack-bot-token) SLACK_BOT_TOKEN="$2"; shift 2 ;;
        --slack-channel-id) SLACK_CHANNEL_ID="$2"; shift 2 ;;
        --github-repo-name) GITHUB_REPO_NAME="$2"; shift 2 ;;
        --github-repo-id) GITHUB_REPO_ID="$2"; shift 2 ;;
        --github-owner) GITHUB_OWNER="$2"; shift 2 ;;
        --github-owner-type) GITHUB_OWNER_TYPE="$2"; shift 2 ;;
        --slack-workspace-id) SLACK_WORKSPACE_ID="$2"; shift 2 ;;
        --slack-workspace-name) SLACK_WORKSPACE_NAME="$2"; shift 2 ;;
        --slack-agent-channel-id) SLACK_AGENT_CHANNEL_ID="$2"; shift 2 ;;
        --slack-agent-channel-name) SLACK_AGENT_CHANNEL_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$AWS_PROFILE" || -z "$PROJECT_NAME" ]]; then
    echo "Error: --profile and --project are required"
    usage
fi

# ── Load config file (CLI flags take precedence) ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/${AWS_PROFILE}.env"

if [[ -f "$CONFIG_FILE" ]]; then
    _cli_github_repo_name="$GITHUB_REPO_NAME"
    _cli_github_repo_id="$GITHUB_REPO_ID"
    _cli_github_owner="$GITHUB_OWNER"
    _cli_github_owner_type="$GITHUB_OWNER_TYPE"
    _cli_slack_workspace_id="$SLACK_WORKSPACE_ID"
    _cli_slack_workspace_name="$SLACK_WORKSPACE_NAME"
    _cli_slack_agent_channel_id="$SLACK_AGENT_CHANNEL_ID"
    _cli_slack_agent_channel_name="$SLACK_AGENT_CHANNEL_NAME"

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    GITHUB_REPO_NAME="${_cli_github_repo_name:-${GITHUB_REPO_NAME:-${GITHUB_REPO:-}}}"
    GITHUB_REPO_ID="${_cli_github_repo_id:-${GITHUB_REPO_ID:-${GITHUB_INTEGRATION_ID:-}}}"
    GITHUB_OWNER="${_cli_github_owner:-${GITHUB_OWNER:-${GITHUB_ORG:-}}}"
    GITHUB_OWNER_TYPE="${_cli_github_owner_type:-${GITHUB_OWNER_TYPE:-user}}"
    SLACK_WORKSPACE_ID="${_cli_slack_workspace_id:-${SLACK_WORKSPACE_ID:-}}"
    SLACK_WORKSPACE_NAME="${_cli_slack_workspace_name:-${SLACK_WORKSPACE_NAME:-}}"
    SLACK_AGENT_CHANNEL_ID="${_cli_slack_agent_channel_id:-${SLACK_AGENT_CHANNEL_ID:-}}"
    SLACK_AGENT_CHANNEL_NAME="${_cli_slack_agent_channel_name:-${SLACK_AGENT_CHANNEL_NAME:-}}"
fi

if [[ "$MULTI_ACCOUNT" == "true" ]]; then
    if [[ -z "$PEER_PROFILE" || -z "$PEER_PROJECT" || -z "$PROVIDER_SERVICES" ]]; then
        echo "Error: --peer-profile, --peer-project, and --provider-services are required when --multi-account is set"
        usage
    fi
fi

if [[ "$ENABLE_SLACK" == "true" ]]; then
    if [[ -z "$SLACK_BOT_TOKEN" || -z "$SLACK_CHANNEL_ID" ]]; then
        echo "Error: --slack-bot-token and --slack-channel-id are required when --enable-slack is set"
        usage
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
CFN_DIR="${SCRIPT_DIR}/cloudformation"
KUBE_DIR="${SCRIPT_DIR}/kubernetes"
AWS_OPTS="--profile $AWS_PROFILE --region $AWS_REGION --no-cli-pager"

# ── Helper functions ──
stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" $AWS_OPTS >/dev/null 2>&1
}

get_stack_status() {
    aws cloudformation describe-stacks --stack-name "$1" \
        --query 'Stacks[0].StackStatus' --output text $AWS_OPTS 2>/dev/null || echo "NOT_EXISTS"
}

get_stack_output() {
    aws cloudformation describe-stacks --stack-name "$1" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
        --output text $AWS_OPTS 2>/dev/null
}

deploy_stack() {
    local stack_name=$1
    local template_file=$2
    shift 2
    local extra_params=("$@")

    local params=(
        "ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME"
        "ParameterKey=Environment,ParameterValue=$PROJECT_NAME"
    )
    for p in "${extra_params[@]}"; do
        params+=("$p")
    done

    if stack_exists "$stack_name"; then
        local status=$(get_stack_status "$stack_name")
        case "$status" in
            CREATE_COMPLETE|UPDATE_COMPLETE)
                print_warning "Stack $stack_name already exists ($status), skipping"
                return 0
                ;;
            ROLLBACK_COMPLETE|CREATE_FAILED)
                print_warning "Stack $stack_name in $status, deleting first..."
                aws cloudformation delete-stack --stack-name "$stack_name" $AWS_OPTS
                aws cloudformation wait stack-delete-complete --stack-name "$stack_name" $AWS_OPTS
                ;;
            *_IN_PROGRESS)
                print_warning "Stack $stack_name is $status, waiting..."
                aws cloudformation wait stack-create-complete --stack-name "$stack_name" $AWS_OPTS 2>/dev/null || \
                aws cloudformation wait stack-update-complete --stack-name "$stack_name" $AWS_OPTS 2>/dev/null || true
                return 0
                ;;
        esac
    fi

    print_status "Creating stack: $stack_name"
    aws cloudformation create-stack \
        --stack-name "$stack_name" \
        --template-body "file://${CFN_DIR}/${template_file}" \
        --parameters "${params[@]}" \
        --capabilities CAPABILITY_NAMED_IAM \
        $AWS_OPTS

    print_status "Waiting for $stack_name..."
    if aws cloudformation wait stack-create-complete --stack-name "$stack_name" $AWS_OPTS; then
        print_status "✓ $stack_name created successfully"
    else
        print_error "✗ $stack_name failed"
        aws cloudformation describe-stack-events --stack-name "$stack_name" $AWS_OPTS \
            --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
            --output table
        exit 1
    fi
}

# ══════════════════════════════════════════
# Phase 1-5: CloudFormation Infrastructure
# ══════════════════════════════════════════

# Foundation: VPC + EKS + RDS + Alarms + GitHub Actions + FIS
deploy_foundation() {
    print_status "═══ Phase 1: VPC Foundation ═══"
    deploy_stack "${PROJECT_NAME}-vpc-foundation" "01-vpc-foundation.yml" \
        "ParameterKey=VpcCidrPrefix,ParameterValue=$VPC_CIDR_PREFIX"

    print_status "═══ Phase 2: EKS Platform ═══"
    deploy_stack "${PROJECT_NAME}-eks-platform" "02-eks-platform.yml"

    print_status "═══ Phase 2: RDS Database ═══"
    deploy_stack "${PROJECT_NAME}-rds-database" "03-rds-database.yml"

    print_status "═══ Phase 3: CloudWatch Alarms ═══"
    deploy_stack "${PROJECT_NAME}-alarms" "06-cloudwatch-alarms.yml"

    print_status "═══ Phase 3: GitHub Actions OIDC ═══"
    deploy_stack "${PROJECT_NAME}-github-actions" "08-github-actions.yml"

    print_status "═══ Phase 3: FIS Experiments ═══"
    deploy_stack "${PROJECT_NAME}-fis" "07-fis-experiments.yml"
}

# DevOps Agent: Agent Space + Associations + Transaction Search + Security Agent
deploy_agent() {
    print_status "═══ Phase 4: DevOps Agent ═══"
    local -a agent_params=()
    if [[ -n "$GITHUB_REPO_NAME" && -n "$GITHUB_REPO_ID" ]]; then
        agent_params+=(
            "ParameterKey=GitHubRepoName,ParameterValue=${GITHUB_REPO_NAME}"
            "ParameterKey=GitHubRepoId,ParameterValue=${GITHUB_REPO_ID}"
            "ParameterKey=GitHubOwner,ParameterValue=${GITHUB_OWNER}"
            "ParameterKey=GitHubOwnerType,ParameterValue=${GITHUB_OWNER_TYPE}"
        )
    fi
    if [[ -n "$SLACK_WORKSPACE_ID" ]]; then
        agent_params+=(
            "ParameterKey=SlackWorkspaceId,ParameterValue=${SLACK_WORKSPACE_ID}"
            "ParameterKey=SlackWorkspaceName,ParameterValue=${SLACK_WORKSPACE_NAME}"
            "ParameterKey=SlackChannelId,ParameterValue=${SLACK_AGENT_CHANNEL_ID}"
            "ParameterKey=SlackChannelName,ParameterValue=${SLACK_AGENT_CHANNEL_NAME}"
        )
    fi

    if [[ "$MULTI_ACCOUNT" == "true" && -n "$PEER_PROFILE" && -n "$PEER_PROJECT" ]]; then
        print_status "Phase 4a: Deploying cross-account DevOps Agent role in peer account..."
        deploy_stack_with_profile "$PEER_PROFILE" "$PEER_PROJECT" \
            "${PEER_PROJECT}-devops-agent-xaccount" "13-devops-agent-secondary-role.yml" \
            "ParameterKey=PrimaryAccountId,ParameterValue=${account_id}" \
            "ParameterKey=PrimaryProjectName,ParameterValue=${PROJECT_NAME}"

        local xaccount_role_arn
        xaccount_role_arn=$(aws cloudformation describe-stacks \
            --stack-name "${PEER_PROJECT}-devops-agent-xaccount" \
            --query "Stacks[0].Outputs[?OutputKey=='CrossAccountRoleArn'].OutputValue" \
            --output text --profile "$PEER_PROFILE" --region "$AWS_REGION" --no-cli-pager)
        local secondary_account_id
        secondary_account_id=$(aws sts get-caller-identity --query Account --output text \
            --profile "$PEER_PROFILE" --no-cli-pager)

        print_status "Phase 4b: Deploying DevOps Agent with source account association..."
        deploy_stack "${PROJECT_NAME}-devops-agent" "04-devops-agent.yml" \
            "ParameterKey=SecondaryAccountId,ParameterValue=${secondary_account_id}" \
            "ParameterKey=SecondaryAccountRoleArn,ParameterValue=${xaccount_role_arn}" \
            "ParameterKey=SecondaryProjectName,ParameterValue=${PEER_PROJECT}" \
            "${agent_params[@]}"
    else
        deploy_stack "${PROJECT_NAME}-devops-agent" "04-devops-agent.yml" \
            "${agent_params[@]}"
    fi

    print_status "═══ Phase 4: Transaction Search ═══"
    deploy_stack "${PROJECT_NAME}-transaction-search" "05-transaction-search.yml"

    print_status "═══ Phase 5: Security Agent SG ═══"
    deploy_stack "${PROJECT_NAME}-security-agent" "08-security-agent.yml"

    print_status "═══ Phase 5: Security Agent Roles ═══"
    deploy_stack "${PROJECT_NAME}-security-role" "10-security-agent-role.yml"
}

# All infra (backward compatible)
deploy_infra() {
    deploy_foundation
    deploy_agent
}

# ══════════════════════════════════════════
# Phase 6: Docker Image Build & ECR Push
# ══════════════════════════════════════════
_ecr_login() {
    local account_id=$1
    print_status "Logging in to ECR..."
    aws ecr get-login-password $AWS_OPTS | \
        docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
}

_build_push() {
    local name=$1 context=$2 ecr_uri=$3 tag=$4
    print_status "Building ${name}..."
    docker build -t "${ecr_uri}:${tag}" "${context}" --platform linux/amd64
    print_status "Pushing ${name} → ${ecr_uri}:${tag}"
    docker push "${ecr_uri}:${tag}"
    print_status "✓ ${name} pushed"
}

build_test_app_images() {
    local account_id=$1
    _ecr_login "$account_id"
    IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)

    local ecr_hasher=$(get_stack_output "${PROJECT_NAME}-eks-platform" "HasherECRRepositoryURI")
    local ecr_rng=$(get_stack_output "${PROJECT_NAME}-eks-platform" "RngECRRepositoryURI")
    local ecr_worker=$(get_stack_output "${PROJECT_NAME}-eks-platform" "WorkerECRRepositoryURI")
    local ecr_webui=$(get_stack_output "${PROJECT_NAME}-eks-platform" "WebuiECRRepositoryURI")

    _build_push "hasher" "${REPO_ROOT}/services/dockercoins/hasher" "${ecr_hasher}" "${IMAGE_TAG}"
    _build_push "rng"    "${REPO_ROOT}/services/dockercoins/rng"    "${ecr_rng}"    "${IMAGE_TAG}"
    _build_push "worker" "${REPO_ROOT}/services/dockercoins/worker" "${ecr_worker}" "${IMAGE_TAG}"
    _build_push "webui"  "${REPO_ROOT}/services/dockercoins/webui"  "${ecr_webui}"  "${IMAGE_TAG}"
}

build_overview_images() {
    local account_id=$1
    _ecr_login "$account_id"
    IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)

    local ecr_prefix="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}"
    local ecr_overview="${ecr_prefix}/overview"
    aws ecr describe-repositories --repository-names "${PROJECT_NAME}/overview" $AWS_OPTS >/dev/null 2>&1 || \
        aws ecr create-repository --repository-name "${PROJECT_NAME}/overview" $AWS_OPTS >/dev/null

    _build_push "overview" "${REPO_ROOT}/services/dashboard" "${ecr_overview}" "${IMAGE_TAG}"
}

build_and_push_images() {
    local account_id=$1
    build_test_app_images "$account_id"
    build_overview_images "$account_id"
}

# ══════════════════════════════════════════
# Phase 7: K8s Resource Deployment
# ══════════════════════════════════════════
_k8s_setup() {
    local account_id=$1
    K8S_CLUSTER_NAME=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")
    K8S_OVERLAY_DIR="${KUBE_DIR}/overlays/_generated"

    print_status "Configuring kubeconfig for ${K8S_CLUSTER_NAME}..."
    aws eks update-kubeconfig \
        --name "${K8S_CLUSTER_NAME}" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --alias "${K8S_CLUSTER_NAME}"

    local nodegroup
    nodegroup=$(aws eks list-nodegroups --cluster-name "${K8S_CLUSTER_NAME}" $AWS_OPTS --query 'nodegroups[0]' --output text)
    print_status "Scaling nodegroup ${nodegroup} to ${NODE_COUNT} nodes..."
    aws eks update-nodegroup-config \
        --cluster-name "${K8S_CLUSTER_NAME}" \
        --nodegroup-name "${nodegroup}" \
        --scaling-config "minSize=1,maxSize=6,desiredSize=${NODE_COUNT}" \
        $AWS_OPTS >/dev/null

    print_status "Waiting for nodes to be Ready..."
    for i in $(seq 1 30); do
        ready=$(kubectl get nodes --context "${K8S_CLUSTER_NAME}" --no-headers 2>/dev/null | grep -c " Ready " || true)
        if [[ "$ready" -ge "$NODE_COUNT" ]]; then
            print_status "✓ ${ready} nodes Ready"
            break
        fi
        sleep 10
    done

    # Slack secret setup
    if [[ "$ENABLE_SLACK" == "true" ]]; then
        local slack_secret="${PROJECT_NAME}-slack-bot-token"
        print_status "Setting up Slack integration..."
        local secret_value="{\"bot_token\":\"${SLACK_BOT_TOKEN}\",\"channel_id\":\"${SLACK_CHANNEL_ID}\"}"
        if aws secretsmanager describe-secret --secret-id "${slack_secret}" $AWS_OPTS >/dev/null 2>&1; then
            aws secretsmanager put-secret-value --secret-id "${slack_secret}" --secret-string "${secret_value}" $AWS_OPTS >/dev/null
            print_status "✓ Slack secret updated"
        else
            aws secretsmanager create-secret --name "${slack_secret}" --secret-string "${secret_value}" \
                --tags "Key=auto-delete,Value=never" "Key=Environment,Value=${PROJECT_NAME}" $AWS_OPTS >/dev/null
            print_status "✓ Slack secret created"
        fi
    fi
}

deploy_k8s_test_app() {
    local account_id=$1
    local image_tag=$2

    local ecr_hasher=$(get_stack_output "${PROJECT_NAME}-eks-platform" "HasherECRRepositoryURI")
    local ecr_rng=$(get_stack_output "${PROJECT_NAME}-eks-platform" "RngECRRepositoryURI")
    local ecr_worker=$(get_stack_output "${PROJECT_NAME}-eks-platform" "WorkerECRRepositoryURI")
    local ecr_webui=$(get_stack_output "${PROJECT_NAME}-eks-platform" "WebuiECRRepositoryURI")
    local db_endpoint=$(get_stack_output "${PROJECT_NAME}-rds-database" "DatabaseEndpoint")
    local events_table=$(get_stack_output "${PROJECT_NAME}-devops-agent" "InvestigationEventsTableName")
    local cleanup_role=$(get_stack_output "${PROJECT_NAME}-eks-platform" "CleanupServiceIAMRoleArn")

    mkdir -p "${K8S_OVERLAY_DIR}/dockercoins"
    cat > "${K8S_OVERLAY_DIR}/dockercoins/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../base/dockercoins

images:
  - name: hasher
    newName: ${ecr_hasher}
    newTag: "${image_tag}"
  - name: rng
    newName: ${ecr_rng}
    newTag: "${image_tag}"
  - name: worker
    newName: ${ecr_worker}
    newTag: "${image_tag}"
  - name: webui
    newName: ${ecr_webui}
    newTag: "${image_tag}"

patches:
  - target:
      kind: Deployment
      name: rng
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "${db_endpoint}"
  - target:
      kind: CronJob
      name: investigation-cleanup
    patch: |
      - op: replace
        path: /spec/jobTemplate/spec/template/spec/containers/0/env/1/value
        value: "${events_table}"
  - target:
      kind: ServiceAccount
      name: investigation-cleanup
    patch: |
      - op: replace
        path: /metadata/annotations/eks.amazonaws.com~1role-arn
        value: "${cleanup_role}"
EOF

    # Append NLB patches for provider services in multi-account mode
    if [[ "$MULTI_ACCOUNT" == "true" && -n "$PROVIDER_SERVICES" ]]; then
        IFS=',' read -ra _provider_list <<< "$PROVIDER_SERVICES"
        for _psvc in "${_provider_list[@]}"; do
            cat >> "${K8S_OVERLAY_DIR}/dockercoins/kustomization.yaml" <<NLBEOF
  - target:
      kind: Service
      name: ${_psvc}
    patch: |
      - op: add
        path: /metadata/annotations
        value:
          service.beta.kubernetes.io/aws-load-balancer-internal: "true"
          service.beta.kubernetes.io/aws-load-balancer-scheme: internal
          service.beta.kubernetes.io/aws-load-balancer-type: nlb
      - op: replace
        path: /spec/type
        value: LoadBalancer
NLBEOF
        done
    fi

    print_status "Deploying dockercoins..."
    kubectl apply -k "${K8S_OVERLAY_DIR}/dockercoins/" --context "${K8S_CLUSTER_NAME}"

    kubectl wait --for=condition=available deployment --all -n dockercoins --timeout=300s --context "${K8S_CLUSTER_NAME}" 2>/dev/null || \
        print_warning "Some dockercoins deployments not ready yet"
}

deploy_k8s_overview() {
    local account_id=$1
    local image_tag=$2

    local ecr_prefix="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}"
    local ecr_overview="${ecr_prefix}/overview"
    local overview_role=$(get_stack_output "${PROJECT_NAME}-eks-platform" "DashboardServiceIAMRoleArn")
    local cluster_name="${K8S_CLUSTER_NAME}"
    local events_table=$(get_stack_output "${PROJECT_NAME}-devops-agent" "InvestigationEventsTableName")
    local runs_table=$(get_stack_output "${PROJECT_NAME}-devops-agent" "ScenarioRunsTableName")
    local webhook_function="${PROJECT_NAME}-alarm-to-webhook"
    local webhook_secret="${PROJECT_NAME}-devops-agent-webhook"
    local slack_secret="${PROJECT_NAME}-slack-bot-token"

    mkdir -p "${K8S_OVERLAY_DIR}/overview"
    cat > "${K8S_OVERLAY_DIR}/overview/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../base/overview

images:
  - name: overview
    newName: ${ecr_overview}
    newTag: "${image_tag}"

patches:
  - target:
      kind: ServiceAccount
      name: overview
    patch: |
      - op: replace
        path: /metadata/annotations/eks.amazonaws.com~1role-arn
        value: "${overview_role}"
  - target:
      kind: ConfigMap
      name: overview-config
    patch: |
      - op: replace
        path: /data/EKS_CLUSTER_NAME
        value: "${cluster_name}"
      - op: replace
        path: /data/EVENTS_TABLE
        value: "${events_table}"
      - op: replace
        path: /data/RUNS_TABLE
        value: "${runs_table}"
      - op: replace
        path: /data/SLACK_SECRET_NAME
        value: "${slack_secret}"
      - op: replace
        path: /data/WEBHOOK_SECRET_NAME
        value: "${webhook_secret}"
      - op: replace
        path: /data/WEBHOOK_FUNCTION_NAME
        value: "${webhook_function}"
      - op: replace
        path: /data/ALARM_PREFIX
        value: "${PROJECT_NAME}"
      - op: replace
        path: /data/PROJECT_NAME
        value: "${PROJECT_NAME}"
EOF

    print_status "Deploying overview..."
    kubectl apply -k "${K8S_OVERLAY_DIR}/overview/" --context "${K8S_CLUSTER_NAME}"

    kubectl wait --for=condition=available deployment --all -n overview --timeout=120s --context "${K8S_CLUSTER_NAME}" 2>/dev/null || \
        print_warning "Overview deployment not ready yet"
}

deploy_k8s() {
    local account_id=$1
    local image_tag=$2
    _k8s_setup "$account_id"
    deploy_k8s_test_app "$account_id" "$image_tag"
    deploy_k8s_overview "$account_id" "$image_tag"
    rm -rf "${K8S_OVERLAY_DIR}"
}

# ══════════════════════════════════════════
# Phase 8: PrivateLink Cross-Account
# ══════════════════════════════════════════
deploy_stack_with_profile() {
    local profile=$1
    local project=$2
    local stack_name=$3
    local template_file=$4
    shift 4
    local extra_params=("$@")

    local cross_opts="--profile $profile --region $AWS_REGION --no-cli-pager"
    local params=(
        "ParameterKey=ProjectName,ParameterValue=$project"
        "ParameterKey=Environment,ParameterValue=$project"
    )
    for p in "${extra_params[@]}"; do
        params+=("$p")
    done

    if aws cloudformation describe-stacks --stack-name "$stack_name" $cross_opts >/dev/null 2>&1; then
        local status
        status=$(aws cloudformation describe-stacks --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' --output text $cross_opts 2>/dev/null || echo "NOT_EXISTS")
        case "$status" in
            CREATE_COMPLETE|UPDATE_COMPLETE)
                print_warning "Stack $stack_name already exists ($status), skipping"
                return 0 ;;
            ROLLBACK_COMPLETE|CREATE_FAILED)
                print_warning "Stack $stack_name in $status, deleting first..."
                aws cloudformation delete-stack --stack-name "$stack_name" $cross_opts
                aws cloudformation wait stack-delete-complete --stack-name "$stack_name" $cross_opts ;;
            *_IN_PROGRESS)
                print_warning "Stack $stack_name is $status, waiting..."
                aws cloudformation wait stack-create-complete --stack-name "$stack_name" $cross_opts 2>/dev/null || true
                return 0 ;;
        esac
    fi

    print_status "Creating stack: $stack_name (cross-account: $profile)"
    aws cloudformation create-stack \
        --stack-name "$stack_name" \
        --template-body "file://${CFN_DIR}/${template_file}" \
        --parameters "${params[@]}" \
        --capabilities CAPABILITY_NAMED_IAM \
        $cross_opts

    print_status "Waiting for $stack_name..."
    if aws cloudformation wait stack-create-complete --stack-name "$stack_name" $cross_opts; then
        print_status "✓ $stack_name created successfully"
    else
        print_error "✗ $stack_name failed"
        exit 1
    fi
}

wait_for_nlb() {
    local service_name=$1
    local namespace=$2
    local context=$3
    local max_wait=300
    local elapsed=0

    print_status "Waiting for NLB for ${service_name}..."
    while [[ $elapsed -lt $max_wait ]]; do
        local hostname
        hostname=$(kubectl get svc "$service_name" -n "$namespace" \
            --context "$context" \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [[ -n "$hostname" && "$hostname" != "null" ]]; then
            local nlb_arn
            nlb_arn=$(aws elbv2 describe-load-balancers \
                --query "LoadBalancers[?DNSName=='${hostname}'].LoadBalancerArn" \
                --output text $AWS_OPTS 2>/dev/null)
            if [[ -n "$nlb_arn" && "$nlb_arn" != "None" ]]; then
                print_status "NLB ready: ${hostname}"
                echo "$nlb_arn"
                return 0
            fi
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    print_error "Timeout waiting for NLB for ${service_name}"
    return 1
}

deploy_privatelink() {
    if [[ "$MULTI_ACCOUNT" != "true" ]]; then
        return 0
    fi

    print_status "══════════════════════════════════════"
    print_status "  Phase 8: PrivateLink Cross-Account"
    print_status "══════════════════════════════════════"

    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text $AWS_OPTS)
    local peer_account_id
    peer_account_id=$(aws sts get-caller-identity --query Account --output text \
        --profile "$PEER_PROFILE" --region "$AWS_REGION" --no-cli-pager)
    local cluster_name
    cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")
    local peer_opts="--profile $PEER_PROFILE --region $AWS_REGION --no-cli-pager"

    IFS=',' read -ra PROVIDER_SVC_LIST <<< "$PROVIDER_SERVICES"

    print_status "This account ($account_id) provides: ${PROVIDER_SVC_LIST[*]}"
    print_status "Peer account ($peer_account_id): $PEER_PROJECT"

    # ── Provider setup (this account) ──
    declare -A ENDPOINT_SVC_NAMES
    for svc in "${PROVIDER_SVC_LIST[@]}"; do
        print_status "── Provider: ${svc} ──"

        local nlb_arn
        nlb_arn=$(wait_for_nlb "$svc" "dockercoins" "$cluster_name")
        if [[ -z "$nlb_arn" ]]; then
            print_error "Failed to get NLB ARN for ${svc}"
            exit 1
        fi

        deploy_stack "${PROJECT_NAME}-privatelink-provider-${svc}" "11-privatelink-provider.yml" \
            "ParameterKey=ServiceName,ParameterValue=${svc}" \
            "ParameterKey=NetworkLoadBalancerArn,ParameterValue=${nlb_arn}" \
            "ParameterKey=AllowedPrincipal,ParameterValue=arn:aws:iam::${peer_account_id}:root"

        local vpce_svc_id
        vpce_svc_id=$(get_stack_output "${PROJECT_NAME}-privatelink-provider-${svc}" "EndpointServiceId")
        ENDPOINT_SVC_NAMES[$svc]="com.amazonaws.vpce.${AWS_REGION}.${vpce_svc_id}"
        print_status "Endpoint Service: ${ENDPOINT_SVC_NAMES[$svc]}"
    done

    # ── Consumer setup in peer account ──
    local peer_cluster
    peer_cluster=$(aws cloudformation describe-stacks \
        --stack-name "${PEER_PROJECT}-eks-platform" \
        --query "Stacks[0].Outputs[?OutputKey=='EKSClusterName'].OutputValue" \
        --output text $peer_opts)

    aws eks update-kubeconfig \
        --name "$peer_cluster" \
        --profile "$PEER_PROFILE" \
        --region "$AWS_REGION" \
        --alias "$peer_cluster"

    for svc in "${PROVIDER_SVC_LIST[@]}"; do
        print_status "── Consumer: ${svc} in peer (${PEER_PROJECT}) ──"

        local endpoint_service_name="${ENDPOINT_SVC_NAMES[$svc]}"

        deploy_stack_with_profile "$PEER_PROFILE" "$PEER_PROJECT" \
            "${PEER_PROJECT}-privatelink-consumer-${svc}" "12-privatelink-consumer.yml" \
            "ParameterKey=ServiceName,ParameterValue=${svc}" \
            "ParameterKey=EndpointServiceName,ParameterValue=${endpoint_service_name}"

        local vpce_id
        vpce_id=$(aws cloudformation describe-stacks \
            --stack-name "${PEER_PROJECT}-privatelink-consumer-${svc}" \
            --query "Stacks[0].Outputs[?OutputKey=='VPCEndpointId'].OutputValue" \
            --output text $peer_opts)

        print_status "Waiting for VPC Endpoint ${vpce_id}..."
        aws ec2 wait vpc-endpoint-available --vpc-endpoint-ids "$vpce_id" $peer_opts 2>/dev/null || true

        local vpce_dns
        vpce_dns=$(aws ec2 describe-vpc-endpoints \
            --vpc-endpoint-ids "$vpce_id" \
            --query 'VpcEndpoints[0].DnsEntries[0].DnsName' \
            --output text $peer_opts)
        print_status "VPC Endpoint DNS: ${vpce_dns}"

        # Scale down deployment in consumer cluster
        kubectl scale deployment "$svc" --replicas=0 \
            -n dockercoins --context "$peer_cluster" 2>/dev/null || true

        # Replace ClusterIP with ExternalName
        kubectl delete svc "$svc" -n dockercoins \
            --context "$peer_cluster" --ignore-not-found

        kubectl apply --context "$peer_cluster" -f - <<EXTEOF
apiVersion: v1
kind: Service
metadata:
  name: ${svc}
  namespace: dockercoins
  labels:
    app: ${svc}
    privatelink: consumer
spec:
  type: ExternalName
  externalName: ${vpce_dns}
  ports:
  - port: 80
EXTEOF
        print_status "✓ ExternalName svc/${svc} created in ${peer_cluster}"
    done

    verify_privatelink
}

verify_privatelink() {
    print_status "═══ PrivateLink Verification ═══"

    local peer_opts="--profile $PEER_PROFILE --region $AWS_REGION --no-cli-pager"
    IFS=',' read -ra PROVIDER_SVC_LIST <<< "$PROVIDER_SERVICES"

    for svc in "${PROVIDER_SVC_LIST[@]}"; do
        local vpce_svc_id
        vpce_svc_id=$(get_stack_output "${PROJECT_NAME}-privatelink-provider-${svc}" "EndpointServiceId")
        local svc_state
        svc_state=$(aws ec2 describe-vpc-endpoint-service-configurations \
            --service-ids "$vpce_svc_id" \
            --query 'ServiceConfigurations[0].ServiceState' \
            --output text $AWS_OPTS 2>/dev/null)
        print_status "Provider ${svc}: ${svc_state}"

        local vpce_id
        vpce_id=$(aws cloudformation describe-stacks \
            --stack-name "${PEER_PROJECT}-privatelink-consumer-${svc}" \
            --query "Stacks[0].Outputs[?OutputKey=='VPCEndpointId'].OutputValue" \
            --output text $peer_opts 2>/dev/null)
        local vpce_state
        vpce_state=$(aws ec2 describe-vpc-endpoints \
            --vpc-endpoint-ids "$vpce_id" \
            --query 'VpcEndpoints[0].State' \
            --output text $peer_opts 2>/dev/null)
        print_status "Consumer ${svc}: ${vpce_state}"
    done

    local peer_cluster
    peer_cluster=$(aws cloudformation describe-stacks \
        --stack-name "${PEER_PROJECT}-eks-platform" \
        --query "Stacks[0].Outputs[?OutputKey=='EKSClusterName'].OutputValue" \
        --output text $peer_opts)

    for svc in "${PROVIDER_SVC_LIST[@]}"; do
        local svc_type
        svc_type=$(kubectl get svc "$svc" -n dockercoins --context "$peer_cluster" \
            -o jsonpath='{.spec.type}' 2>/dev/null)
        local svc_ext
        svc_ext=$(kubectl get svc "$svc" -n dockercoins --context "$peer_cluster" \
            -o jsonpath='{.spec.externalName}' 2>/dev/null)
        print_status "K8s svc/${svc} in peer: type=${svc_type} externalName=${svc_ext}"
    done
}

# ══════════════════════════════════════════
# Main
# ══════════════════════════════════════════
main() {
    print_status "=== Environment Deployment ==="
    print_status "Project: $PROJECT_NAME"
    print_status "Profile: $AWS_PROFILE"
    print_status "Region:  $AWS_REGION"
    print_status "Nodes:   $NODE_COUNT"
    print_status "VPC:     ${VPC_CIDR_PREFIX}.0.0/16"
    if [[ -n "$ONLY_UNIT" ]]; then
        print_status "Unit:    $ONLY_UNIT"
    fi
    if [[ "$MULTI_ACCOUNT" == "true" ]]; then
        print_status "Multi:   enabled (peer: $PEER_PROFILE / $PEER_PROJECT)"
        print_status "Provide: $PROVIDER_SERVICES"
    fi
    echo ""

    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text $AWS_OPTS)
    print_status "Account: $account_id"
    echo ""

    IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)

    # ── Unit-specific deployment ──
    if [[ -n "$ONLY_UNIT" ]]; then
        case "$ONLY_UNIT" in
            foundation)
                print_status "══════════════════════════════════════"
                print_status "  Unit: Foundation (VPC+EKS+RDS+Alarms+FIS)"
                print_status "══════════════════════════════════════"
                deploy_foundation
                ;;
            agent)
                print_status "══════════════════════════════════════"
                print_status "  Unit: DevOps Agent"
                print_status "══════════════════════════════════════"
                deploy_agent
                ;;
            test-app)
                print_status "══════════════════════════════════════"
                print_status "  Unit: Test App (DockerCoins)"
                print_status "══════════════════════════════════════"
                build_test_app_images "$account_id"
                _k8s_setup "$account_id"
                deploy_k8s_test_app "$account_id" "$IMAGE_TAG"
                rm -rf "${K8S_OVERLAY_DIR}"
                ;;
            overview)
                print_status "══════════════════════════════════════"
                print_status "  Unit: Overview App"
                print_status "══════════════════════════════════════"
                build_overview_images "$account_id"
                _k8s_setup "$account_id"
                deploy_k8s_overview "$account_id" "$IMAGE_TAG"
                rm -rf "${K8S_OVERLAY_DIR}"
                ;;
            *)
                print_error "Unknown unit: $ONLY_UNIT"
                print_error "Valid units: foundation, agent, test-app, overview"
                exit 1
                ;;
        esac

        echo ""
        print_status "Done! (unit: $ONLY_UNIT)"
        return
    fi

    # ── Full deployment (original flow with --skip-* support) ──
    if [[ "$SKIP_INFRA" == "false" ]]; then
        print_status "══════════════════════════════════════"
        print_status "  Phases 1-5: CloudFormation Infra"
        print_status "══════════════════════════════════════"
        deploy_infra
    else
        print_warning "Skipping infrastructure deployment (--skip-infra)"
    fi

    if [[ "$SKIP_BUILD" == "false" ]]; then
        print_status "══════════════════════════════════════"
        print_status "  Phase 6: Docker Build & ECR Push"
        print_status "══════════════════════════════════════"
        build_and_push_images "$account_id"
    else
        print_warning "Skipping image build (--skip-build)"
    fi

    if [[ "$SKIP_K8S" == "false" ]]; then
        print_status "══════════════════════════════════════"
        print_status "  Phase 7: K8s Resource Deployment"
        print_status "══════════════════════════════════════"
        deploy_k8s "$account_id" "$IMAGE_TAG"
    else
        print_warning "Skipping K8s deployment (--skip-k8s)"
    fi

    # Phase 8: PrivateLink
    if [[ "$MULTI_ACCOUNT" == "true" ]]; then
        deploy_privatelink
    fi

    # Summary
    echo ""
    print_status "═══ Deployment Summary ═══"
    aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}')].{Name:StackName,Status:StackStatus}" \
        --output table $AWS_OPTS

    echo ""
    print_status "K8s Workload Status:"
    local cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")
    kubectl get deployments -A --context "${cluster_name}" 2>/dev/null || true
    echo ""
    kubectl get pods -A --context "${cluster_name}" 2>/dev/null || true

    echo ""
    print_status "Done!"
}

main "$@"
