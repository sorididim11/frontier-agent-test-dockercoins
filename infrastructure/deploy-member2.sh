#!/bin/bash
# member2-acc 전체 인프라 배포 스크립트
# ProjectName=devops-agent-test-m2 로 기존 스택과 충돌 없이 새로 배포

set -e

ENV_PROFILE="${ENV_PROFILE:-member2-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
DEPLOY_XACCOUNT_ROLE=false
PRIMARY_ACCOUNT_ID=""
PRIMARY_PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --xaccount-role)        DEPLOY_XACCOUNT_ROLE=true; shift ;;
        --primary-account-id)   PRIMARY_ACCOUNT_ID="$2"; shift 2 ;;
        --primary-project)      PRIMARY_PROJECT_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ "$DEPLOY_XACCOUNT_ROLE" == "true" ]]; then
    if [[ -z "$PRIMARY_ACCOUNT_ID" || -z "$PRIMARY_PROJECT_NAME" ]]; then
        echo "Error: --primary-account-id and --primary-project are required with --xaccount-role"
        exit 1
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CFN_DIR="$(cd "$(dirname "$0")/cloudformation" && pwd)"

stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" $AWS_OPTS >/dev/null 2>&1
}

get_stack_status() {
    aws cloudformation describe-stacks --stack-name "$1" \
        --query 'Stacks[0].StackStatus' --output text $AWS_OPTS 2>/dev/null || echo "NOT_EXISTS"
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

main() {
    print_status "=== member2-acc Full Deployment ==="
    print_status "Project: $PROJECT_NAME"
    print_status "Profile: $AWS_PROFILE"
    print_status "Region:  $AWS_REGION"
    echo ""

    # Verify AWS credentials
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text $AWS_OPTS)
    print_status "Account: $account_id"
    echo ""

    # ── Phase 1: VPC Foundation ──
    print_status "═══ Phase 1: VPC Foundation ═══"
    deploy_stack "${PROJECT_NAME}-vpc-foundation" "01-vpc-foundation.yml"

    # ── Phase 2: EKS + RDS (sequential — RDS needs eks-cluster-sg-id) ──
    print_status "═══ Phase 2: EKS Platform ═══"
    deploy_stack "${PROJECT_NAME}-eks-platform" "02-eks-platform.yml"

    print_status "═══ Phase 2: RDS Database ═══"
    deploy_stack "${PROJECT_NAME}-rds-database" "03-rds-database.yml"

    # ── Phase 3: Independent stacks (can run in parallel, but sequential for simplicity) ──
    print_status "═══ Phase 3: CloudWatch Alarms ═══"
    deploy_stack "${PROJECT_NAME}-alarms" "06-cloudwatch-alarms.yml"

    print_status "═══ Phase 3: Transaction Search ═══"
    deploy_stack "${PROJECT_NAME}-transaction-search" "05-transaction-search.yml"

    print_status "═══ Phase 3: GitHub Actions OIDC ═══"
    deploy_stack "${PROJECT_NAME}-github-actions" "08-github-actions.yml"

    # ── Phase 4: App integration (depends on alarms SNS topic + VPC/EKS) ──
    print_status "═══ Phase 4: DevOps Agent ═══"
    deploy_stack "${PROJECT_NAME}-devops-agent" "04-devops-agent.yml"

    if [[ "$DEPLOY_XACCOUNT_ROLE" == "true" ]]; then
        print_status "═══ Phase 4.5: Cross-Account DevOps Agent Role + Association ═══"
        deploy_stack "${PROJECT_NAME}-devops-agent-xaccount" "13-devops-agent-secondary-role.yml" \
            "ParameterKey=PrimaryAccountId,ParameterValue=${PRIMARY_ACCOUNT_ID}" \
            "ParameterKey=PrimaryProjectName,ParameterValue=${PRIMARY_PROJECT_NAME}"

        print_status "═══ Phase 4.6: Cross-Account Dashboard Access (multi-cluster kubectl) ═══"
        deploy_stack "${PROJECT_NAME}-dashboard-xaccount" "14-dashboard-cross-account-access.yml" \
            "ParameterKey=PrimaryAccountId,ParameterValue=${PRIMARY_ACCOUNT_ID}" \
            "ParameterKey=PrimaryDashboardRoleArn,ParameterValue=arn:aws:iam::${PRIMARY_ACCOUNT_ID}:role/${PRIMARY_PROJECT_NAME}-dashboard-role"
    fi

    print_status "═══ Phase 4: FIS Experiments ═══"
    deploy_stack "${PROJECT_NAME}-fis" "07-fis-experiments.yml"

    # ── Phase 5: Security Agent (depends on VPC) ──
    print_status "═══ Phase 5: Security Agent SG ═══"
    deploy_stack "${PROJECT_NAME}-security-agent" "08-security-agent.yml"

    print_status "═══ Phase 5: Security Agent Roles ═══"
    deploy_stack "${PROJECT_NAME}-security-role" "10-security-agent-role.yml"

    # Route53 skipped — needs ELB DNS parameter (deploy after K8s app is running)

    # ── Phase 6: K8s Workloads (Kustomize overlays) ──
    print_status "═══ Phase 6: K8s Workloads ═══"
    KUBE_DIR="$(cd "$(dirname "$0")/../infrastructure/kubernetes" 2>/dev/null && pwd)" || \
    KUBE_DIR="$(cd "$(dirname "$0")/kubernetes" && pwd)"

    print_status "Configuring kubeconfig for ${PROJECT_NAME}-cluster..."
    aws eks update-kubeconfig \
        --name "${PROJECT_NAME}-cluster" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --alias "${PROJECT_NAME}-cluster"

    print_status "Deploying dockercoins..."
    kubectl apply -k "${KUBE_DIR}/overlays/${AWS_PROFILE}/dockercoins/" --context "${PROJECT_NAME}-cluster"

    print_status "Deploying dashboard..."
    kubectl apply -k "${KUBE_DIR}/overlays/${AWS_PROFILE}/dashboard/" --context "${PROJECT_NAME}-cluster"

    print_status "Waiting for deployments to be ready..."
    kubectl wait --for=condition=available deployment --all -n dockercoins --timeout=120s --context "${PROJECT_NAME}-cluster" 2>/dev/null || \
        print_warning "Some dockercoins deployments not ready yet (images may need to be pushed first)"
    kubectl wait --for=condition=available deployment --all -n dashboard --timeout=120s --context "${PROJECT_NAME}-cluster" 2>/dev/null || \
        print_warning "Dashboard deployment not ready yet (image may need to be pushed first)"

    # ── Summary ──
    echo ""
    print_status "═══ Deployment Summary ═══"
    aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}')].{Name:StackName,Status:StackStatus}" \
        --output table $AWS_OPTS

    echo ""
    print_status "EKS Cluster:"
    aws eks describe-cluster --name "${PROJECT_NAME}-cluster" \
        --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' \
        --output table $AWS_OPTS 2>/dev/null || print_warning "EKS cluster not ready yet"

    echo ""
    print_status "K8s Workload Status:"
    kubectl get deployments -A --context "${PROJECT_NAME}-cluster" 2>/dev/null || true

    print_status "Done! Next steps:"
    echo "  1. Build and push Docker images to member2-acc ECR repos"
    echo "  2. Get WebUI ELB DNS: kubectl get svc webui -n dockercoins --context ${PROJECT_NAME}-cluster"
    echo "  3. Deploy Route53 stack with WebUIElbDns parameter"
}

main "$@"
