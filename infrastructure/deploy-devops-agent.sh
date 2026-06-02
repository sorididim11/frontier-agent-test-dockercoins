#!/bin/bash
# DevOps Agent 개별 배포 스크립트
# CFN 스택: 04-devops-agent, 05-transaction-search, 08-security-agent, 10-security-agent-role
#
# 사용법:
#   ./deploy-devops-agent.sh --profile member1-acc --project devops-agent-test
#   ./deploy-devops-agent.sh --profile member1-acc --project devops-agent-test \
#       --github-repo-name my-repo --github-owner my-org \
#       --slack-workspace-id T0XXX --slack-agent-channel-id C0XXX
#
# 전제: Foundation 스택 (01-vpc, 02-eks, 06-alarms)이 이미 배포되어 있어야 합니다.
#       04-devops-agent.yml은 alarm-topic-arn, subnet, SG를 ImportValue로 참조합니다.

set -e

# ── Parse arguments ──
AWS_REGION="us-east-1"
GITHUB_REPO_NAME=""
GITHUB_REPO_ID=""
GITHUB_OWNER=""
GITHUB_OWNER_TYPE="user"
SLACK_WORKSPACE_ID=""
SLACK_WORKSPACE_NAME=""
SLACK_AGENT_CHANNEL_ID=""
SLACK_AGENT_CHANNEL_NAME=""
MULTI_ACCOUNT=false
PEER_PROFILE=""
PEER_PROJECT=""

usage() {
    echo "Usage: $0 --profile <aws-profile> --project <project-name> [options]"
    echo ""
    echo "Required:"
    echo "  --profile    AWS CLI profile name"
    echo "  --project    Project name (CloudFormation ProjectName parameter)"
    echo ""
    echo "Options:"
    echo "  --region     AWS region (default: us-east-1)"
    echo ""
    echo "Agent Data Sources:"
    echo "  --github-repo-name NAME  GitHub repo name"
    echo "  --github-repo-id ID      GitHub repo numeric ID"
    echo "  --github-owner OWNER     GitHub repo owner"
    echo "  --github-owner-type TYPE organization|user (default: user)"
    echo "  --slack-workspace-id ID  Slack workspace ID e.g. T0XXXXXXX"
    echo "  --slack-workspace-name N Slack workspace display name"
    echo "  --slack-agent-channel-id ID  Slack channel ID"
    echo "  --slack-agent-channel-name N Slack channel name"
    echo ""
    echo "Cross-Account:"
    echo "  --multi-account          Enable cross-account DevOps Agent role"
    echo "  --peer-profile PROFILE   Peer account AWS CLI profile"
    echo "  --peer-project PROJECT   Peer account CFN ProjectName"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)  AWS_PROFILE="$2"; shift 2 ;;
        --project)  PROJECT_NAME="$2"; shift 2 ;;
        --region)   AWS_REGION="$2"; shift 2 ;;
        --github-repo-name) GITHUB_REPO_NAME="$2"; shift 2 ;;
        --github-repo-id) GITHUB_REPO_ID="$2"; shift 2 ;;
        --github-owner) GITHUB_OWNER="$2"; shift 2 ;;
        --github-owner-type) GITHUB_OWNER_TYPE="$2"; shift 2 ;;
        --slack-workspace-id) SLACK_WORKSPACE_ID="$2"; shift 2 ;;
        --slack-workspace-name) SLACK_WORKSPACE_NAME="$2"; shift 2 ;;
        --slack-agent-channel-id) SLACK_AGENT_CHANNEL_ID="$2"; shift 2 ;;
        --slack-agent-channel-name) SLACK_AGENT_CHANNEL_NAME="$2"; shift 2 ;;
        --multi-account) MULTI_ACCOUNT=true; shift ;;
        --peer-profile) PEER_PROFILE="$2"; shift 2 ;;
        --peer-project) PEER_PROJECT="$2"; shift 2 ;;
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CFN_DIR="${SCRIPT_DIR}/cloudformation"
AWS_OPTS="--profile $AWS_PROFILE --region $AWS_REGION --no-cli-pager"

# ── Helper functions (same pattern as deploy.sh) ──
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

# ── Pre-flight checks ──
check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! aws sts get-caller-identity $AWS_OPTS >/dev/null 2>&1; then
        print_error "AWS CLI not configured for profile $AWS_PROFILE"
        exit 1
    fi

    local required_stacks=(
        "${PROJECT_NAME}-vpc-foundation"
        "${PROJECT_NAME}-eks-platform"
        "${PROJECT_NAME}-alarms"
    )
    for stack in "${required_stacks[@]}"; do
        if ! stack_exists "$stack"; then
            print_error "Prerequisite stack not found: $stack"
            print_error "Run deploy-infrastructure.sh or deploy.sh first to create foundation stacks"
            exit 1
        fi
        local status=$(get_stack_status "$stack")
        if [[ "$status" != "CREATE_COMPLETE" && "$status" != "UPDATE_COMPLETE" ]]; then
            print_error "Prerequisite stack $stack is in state: $status"
            exit 1
        fi
    done
    print_status "✓ All prerequisite stacks exist"
}

# ── Main ──
main() {
    print_status "=== DevOps Agent Deployment ==="
    print_status "Project: $PROJECT_NAME"
    print_status "Profile: $AWS_PROFILE"
    print_status "Region:  $AWS_REGION"
    echo ""

    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text $AWS_OPTS)
    print_status "Account: $account_id"
    echo ""

    check_prerequisites

    # ── DevOps Agent Space + Associations + Webhook ──
    print_status "═══ DevOps Agent Space ═══"
    local -a agent_params=()
    if [[ -n "$GITHUB_REPO_NAME" ]]; then
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
        print_status "Deploying cross-account DevOps Agent role in peer account..."
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

        deploy_stack "${PROJECT_NAME}-devops-agent" "04-devops-agent.yml" \
            "ParameterKey=SecondaryAccountId,ParameterValue=${secondary_account_id}" \
            "ParameterKey=SecondaryAccountRoleArn,ParameterValue=${xaccount_role_arn}" \
            "ParameterKey=SecondaryProjectName,ParameterValue=${PEER_PROJECT}" \
            "${agent_params[@]}"
    else
        deploy_stack "${PROJECT_NAME}-devops-agent" "04-devops-agent.yml" \
            "${agent_params[@]}"
    fi

    # ── Transaction Search ──
    print_status "═══ Transaction Search ═══"
    deploy_stack "${PROJECT_NAME}-transaction-search" "05-transaction-search.yml"

    # ── Security Agent ──
    print_status "═══ Security Agent ═══"
    deploy_stack "${PROJECT_NAME}-security-agent" "08-security-agent.yml"
    deploy_stack "${PROJECT_NAME}-security-role" "10-security-agent-role.yml"

    # ── Summary ──
    echo ""
    print_status "═══ DevOps Agent Deployment Summary ═══"
    aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}') && (contains(StackName, 'devops-agent') || contains(StackName, 'transaction') || contains(StackName, 'security'))].{Name:StackName,Status:StackStatus}" \
        --output table $AWS_OPTS

    local space_id
    space_id=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-devops-agent" \
        --query "Stacks[0].Outputs[?OutputKey=='AgentSpaceId'].OutputValue" \
        --output text $AWS_OPTS 2>/dev/null || echo "N/A")

    echo ""
    print_status "Agent Space ID: $space_id"
    print_status "Done!"
}

main "$@"
