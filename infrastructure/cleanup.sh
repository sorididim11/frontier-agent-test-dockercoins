#!/bin/bash
# 범용 전체 환경 정리 스크립트 (deploy.sh의 역순)
# 사용법: ./cleanup.sh --profile <aws-profile> --project <project-name> [options]
#
# Unit별 선택 삭제:
#   --only foundation    Foundation 인프라만 (VPC, EKS, RDS, Alarms, GitHub Actions, FIS)
#   --only agent         DevOps Agent만 (Agent Space, Transaction Search, Security Agent)
#   --only test-app      테스트 앱만 (K8s dockercoins namespace)
#   --only dashboard     Dashboard만 (K8s dashboard namespace + ECR repo)
#   (미지정 시 전체 삭제)

set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Parse arguments ──
AWS_REGION="us-east-1"
MULTI_ACCOUNT=false
PEER_PROFILE=""
PEER_PROJECT=""
PROVIDER_SERVICES=""
ONLY_UNIT=""
DRY_RUN=false
FORCE=false
MAX_RETRIES=3

usage() {
    echo "Usage: $0 --profile <aws-profile> --project <project-name> [options]"
    echo ""
    echo "Required:"
    echo "  --profile    AWS CLI profile name"
    echo "  --project    Project name (CloudFormation ProjectName)"
    echo ""
    echo "Options:"
    echo "  --region     AWS region (default: us-east-1)"
    echo "  --only UNIT  Delete only one unit: foundation|agent|test-app|dashboard"
    echo "  --dry-run    List what would be deleted without actually deleting"
    echo "  --force      Skip confirmation prompt"
    echo "  --multi-account         Enable cross-account cleanup"
    echo "  --peer-profile PROFILE  Peer account AWS CLI profile"
    echo "  --peer-project PROJECT  Peer account project name"
    echo "  --provider-services SVC Comma-separated services (e.g. hasher,rng)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)  AWS_PROFILE="$2"; shift 2 ;;
        --project)  PROJECT_NAME="$2"; shift 2 ;;
        --region)   AWS_REGION="$2"; shift 2 ;;
        --only)     ONLY_UNIT="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --force)    FORCE=true; shift ;;
        --multi-account) MULTI_ACCOUNT=true; shift ;;
        --peer-profile)  PEER_PROFILE="$2"; shift 2 ;;
        --peer-project)  PEER_PROJECT="$2"; shift 2 ;;
        --provider-services) PROVIDER_SERVICES="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$AWS_PROFILE" || -z "$PROJECT_NAME" ]]; then
    echo "Error: --profile and --project are required"
    usage
fi

if [[ "$MULTI_ACCOUNT" == "true" && ( -z "$PEER_PROFILE" || -z "$PEER_PROJECT" ) ]]; then
    echo "Error: --peer-profile and --peer-project are required when --multi-account is set"
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── AWS helpers ──
_aws() { aws "$@" --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager; }
_aws_peer() { aws "$@" --profile "$PEER_PROFILE" --region "$AWS_REGION" --no-cli-pager; }

stack_exists() { _aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; }
stack_exists_peer() { _aws_peer cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; }

get_stack_status() {
    _aws cloudformation describe-stacks --stack-name "$1" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS"
}

get_stack_output() {
    _aws cloudformation describe-stacks --stack-name "$1" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null
}

# ── Stack deletion with retry ──
delete_stack() {
    local stack_name=$1
    local profile_flag=""
    [[ "${2:-}" == "peer" ]] && profile_flag="peer"

    local _do_aws=_aws
    [[ "$profile_flag" == "peer" ]] && _do_aws=_aws_peer

    local _exists=stack_exists
    [[ "$profile_flag" == "peer" ]] && _exists=stack_exists_peer

    if ! $_exists "$stack_name"; then
        print_warning "$stack_name does not exist, skipping"
        return 0
    fi

    local status
    status=$($_do_aws cloudformation describe-stacks --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

    case "$status" in
        DELETE_COMPLETE|NOT_EXISTS)
            print_warning "$stack_name already deleted"
            return 0 ;;
        DELETE_IN_PROGRESS)
            print_status "$stack_name already deleting, waiting..."
            $_do_aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null || true
            return 0 ;;
        DELETE_FAILED)
            print_warning "$stack_name in DELETE_FAILED, retrying..."
            $_do_aws cloudformation delete-stack --stack-name "$stack_name"
            $_do_aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null && return 0
            print_error "$stack_name still DELETE_FAILED after retry"
            return 1 ;;
    esac

    print_status "Deleting $stack_name..."
    $_do_aws cloudformation delete-stack --stack-name "$stack_name"
    if $_do_aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null; then
        print_status "✓ $stack_name deleted"
        return 0
    fi

    print_error "✗ $stack_name delete failed"
    return 1
}

# Initiate deletion without waiting
delete_stack_async() {
    local stack_name=$1
    local profile_flag="${2:-}"
    local _do_aws=_aws
    local _exists=stack_exists
    [[ "$profile_flag" == "peer" ]] && _do_aws=_aws_peer && _exists=stack_exists_peer

    if ! $_exists "$stack_name"; then
        return 0
    fi

    local status
    status=$($_do_aws cloudformation describe-stacks --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

    case "$status" in
        DELETE_COMPLETE|NOT_EXISTS) return 0 ;;
        DELETE_IN_PROGRESS) return 0 ;;
    esac

    print_status "Initiating delete: $stack_name"
    $_do_aws cloudformation delete-stack --stack-name "$stack_name"
}

# Wait for multiple stacks to finish deleting
wait_for_stacks() {
    local profile_flag="${1:-}"; shift
    local stacks=("$@")
    local _do_aws=_aws
    [[ "$profile_flag" == "peer" ]] && _do_aws=_aws_peer

    for stack_name in "${stacks[@]}"; do
        $_do_aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null
        local status
        status=$($_do_aws cloudformation describe-stacks --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")
        if [[ "$status" == "DELETE_FAILED" ]]; then
            print_error "✗ $stack_name → DELETE_FAILED"
        else
            print_status "✓ $stack_name deleted"
        fi
    done
}

# ══════════════════════════════════════════
# Pre-cleanup: K8s namespace removal
# ══════════════════════════════════════════
cleanup_k8s_namespaces() {
    local cluster_name
    cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")

    if [[ -z "$cluster_name" || "$cluster_name" == "None" ]]; then
        print_warning "EKS cluster not found, skipping K8s cleanup"
        return 0
    fi

    print_status "Configuring kubeconfig for ${cluster_name}..."
    _aws eks update-kubeconfig --name "$cluster_name" --alias "$cluster_name" >/dev/null 2>&1 || true

    if ! kubectl get ns --context "$cluster_name" >/dev/null 2>&1; then
        print_warning "Cannot reach cluster ${cluster_name}, skipping K8s cleanup"
        return 0
    fi

    local namespaces=("dockercoins" "dashboard" "splunk")
    for ns in "${namespaces[@]}"; do
        if kubectl get ns "$ns" --context "$cluster_name" >/dev/null 2>&1; then
            print_status "Deleting namespace $ns..."
            # Clear LB finalizers first to avoid stuck deletions
            for svc in $(kubectl get svc -n "$ns" --context "$cluster_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                kubectl patch svc "$svc" -n "$ns" --context "$cluster_name" \
                    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            done
            kubectl delete namespace "$ns" --context "$cluster_name" --ignore-not-found --wait=false
        fi
    done

    # Wait for namespace termination (max 5 min)
    local elapsed=0
    while [[ $elapsed -lt 300 ]]; do
        local stuck=false
        for ns in "${namespaces[@]}"; do
            local ns_status
            ns_status=$(kubectl get ns "$ns" --context "$cluster_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
            if [[ "$ns_status" == "Terminating" ]]; then
                # Force-remove namespace finalizers
                kubectl get ns "$ns" --context "$cluster_name" -o json 2>/dev/null | \
                    python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null | \
                    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - --context "$cluster_name" 2>/dev/null || true
                stuck=true
            fi
        done
        $stuck || break
        sleep 10
        elapsed=$((elapsed + 10))
    done

    print_status "K8s namespaces cleaned"
}

# ══════════════════════════════════════════
# PrivateLink connection cleanup
# ══════════════════════════════════════════
reject_privatelink_connections() {
    local vpce_svc_id=$1
    if [[ -z "$vpce_svc_id" || "$vpce_svc_id" == "None" ]]; then return 0; fi

    local connections
    connections=$(_aws ec2 describe-vpc-endpoint-connections \
        --filters "Name=service-id,Values=$vpce_svc_id" \
        --query 'VpcEndpointConnections[?VpcEndpointState!=`deleted` && VpcEndpointState!=`rejected`].VpcEndpointId' \
        --output text 2>/dev/null)

    if [[ -n "$connections" && "$connections" != "None" ]]; then
        print_status "Rejecting PrivateLink connections on $vpce_svc_id..."
        for vpce_id in $connections; do
            _aws ec2 reject-vpc-endpoint-connections \
                --service-id "$vpce_svc_id" --vpc-endpoint-ids "$vpce_id" >/dev/null 2>&1 || true
        done
    fi
}

# ══════════════════════════════════════════
# ECR force cleanup
# ══════════════════════════════════════════
force_delete_ecr_repos() {
    local repos=("${PROJECT_NAME}/hasher" "${PROJECT_NAME}/rng" "${PROJECT_NAME}/worker" "${PROJECT_NAME}/webui" "${PROJECT_NAME}/dashboard")
    for repo in "${repos[@]}"; do
        if _aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1; then
            print_status "Force-deleting ECR repo: $repo"
            _aws ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 || true
        fi
    done
}

# EKS cluster log group survives stack deletion
cleanup_eks_log_group() {
    local log_group="/aws/eks/${PROJECT_NAME}-cluster/cluster"
    if _aws logs describe-log-groups --log-group-name-prefix "$log_group" \
        --query "logGroups[?logGroupName=='$log_group'].logGroupName" --output text 2>/dev/null | grep -q "$log_group"; then
        print_status "Deleting EKS log group: $log_group"
        _aws logs delete-log-group --log-group-name "$log_group" 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════
# Orphaned NLB/ENI cleanup
# ══════════════════════════════════════════
cleanup_orphaned_lbs() {
    local vpc_id=$1
    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then return 0; fi

    local lb_arns
    lb_arns=$(_aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null)

    for arn in $lb_arns; do
        [[ -z "$arn" || "$arn" == "None" ]] && continue
        print_status "Deleting orphaned load balancer: $arn"
        # Delete listeners first
        local listeners
        listeners=$(_aws elbv2 describe-listeners --load-balancer-arn "$arn" \
            --query 'Listeners[].ListenerArn' --output text 2>/dev/null)
        for l in $listeners; do
            _aws elbv2 delete-listener --listener-arn "$l" 2>/dev/null || true
        done
        # Delete target groups
        local tgs
        tgs=$(_aws elbv2 describe-target-groups --load-balancer-arn "$arn" \
            --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null)
        _aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
        for tg in $tgs; do
            _aws elbv2 delete-target-group --target-group-arn "$tg" 2>/dev/null || true
        done
    done

    if [[ -n "$lb_arns" && "$lb_arns" != "None" ]]; then
        print_status "Waiting for NLB ENIs to release..."
        local elapsed=0
        while [[ $elapsed -lt 300 ]]; do
            local eni_count
            eni_count=$(_aws ec2 describe-network-interfaces \
                --filters "Name=vpc-id,Values=${vpc_id}" "Name=interface-type,Values=network_load_balancer" \
                --query 'length(NetworkInterfaces)' --output text 2>/dev/null)
            [[ "$eni_count" == "0" || -z "$eni_count" ]] && break
            sleep 15
            elapsed=$((elapsed + 15))
        done
    fi
}

cleanup_orphaned_enis() {
    local vpc_id=$1
    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then return 0; fi

    # Detach and delete available ENIs left by Lambda/EKS
    local enis
    enis=$(_aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)

    for eni in $enis; do
        [[ -z "$eni" || "$eni" == "None" ]] && continue
        print_status "Deleting orphaned ENI: $eni"
        _aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
    done
}

cleanup_orphaned_sgs() {
    local vpc_id=$1
    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then return 0; fi

    # K8s and ELB create SGs outside CFN; delete all non-default SGs in the VPC
    local sgs
    sgs=$(_aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)

    for sg in $sgs; do
        [[ -z "$sg" || "$sg" == "None" ]] && continue
        # Remove ingress/egress rules referencing other SGs first
        _aws ec2 revoke-security-group-ingress --group-id "$sg" \
            --ip-permissions "$(_aws ec2 describe-security-groups --group-ids "$sg" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
        _aws ec2 revoke-security-group-egress --group-id "$sg" \
            --ip-permissions "$(_aws ec2 describe-security-groups --group-ids "$sg" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
        print_status "Deleting orphaned SG: $sg"
        _aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    done
}

# ══════════════════════════════════════════
# Secrets Manager cleanup
# ══════════════════════════════════════════
cleanup_secrets() {
    local secret_name="${PROJECT_NAME}-slack-bot-token"
    if _aws secretsmanager describe-secret --secret-id "$secret_name" >/dev/null 2>&1; then
        print_status "Deleting secret: $secret_name"
        _aws secretsmanager delete-secret --secret-id "$secret_name" \
            --force-delete-without-recovery >/dev/null 2>&1 || true
    fi
}

# ══════════════════════════════════════════
# Dry-run report
# ══════════════════════════════════════════
dry_run_report() {
    echo ""
    echo -e "${GREEN}=== Cleanup Dry Run ===${NC}"
    echo -e "Project: ${PROJECT_NAME}"
    echo -e "Profile: ${AWS_PROFILE}"
    echo -e "Region:  ${AWS_REGION}"
    if [[ -n "$ONLY_UNIT" ]]; then
        echo -e "Unit:    ${ONLY_UNIT}"
    fi
    echo ""

    # List existing stacks
    echo -e "${YELLOW}[CFN Stacks]${NC}"
    _aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
        --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}')].{Name:StackName,Status:StackStatus}" \
        --output table 2>/dev/null || echo "  (none found)"

    if [[ "$MULTI_ACCOUNT" == "true" && -n "$PEER_PROJECT" ]]; then
        echo ""
        echo -e "${YELLOW}[Peer CFN Stacks]${NC}"
        _aws_peer cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
            --query "StackSummaries[?contains(StackName, '${PEER_PROJECT}')].{Name:StackName,Status:StackStatus}" \
            --output table 2>/dev/null || echo "  (none found)"
    fi

    # ECR repos
    echo ""
    echo -e "${YELLOW}[ECR Repos]${NC}"
    for repo in hasher rng worker webui dashboard; do
        if _aws ecr describe-repositories --repository-names "${PROJECT_NAME}/$repo" >/dev/null 2>&1; then
            local count
            count=$(_aws ecr describe-images --repository-name "${PROJECT_NAME}/$repo" \
                --query 'length(imageDetails)' --output text 2>/dev/null)
            echo "  ${PROJECT_NAME}/$repo ($count images)"
        fi
    done

    # K8s namespaces
    local cluster_name
    cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")
    if [[ -n "$cluster_name" && "$cluster_name" != "None" ]]; then
        echo ""
        echo -e "${YELLOW}[K8s Namespaces]${NC} (cluster: $cluster_name)"
        for ns in dockercoins dashboard splunk; do
            kubectl get ns "$ns" --context "$cluster_name" >/dev/null 2>&1 && echo "  $ns" || true
        done
    fi

    echo ""
    echo -e "${YELLOW}[Secrets Manager]${NC}"
    _aws secretsmanager describe-secret --secret-id "${PROJECT_NAME}-slack-bot-token" \
        --query 'Name' --output text 2>/dev/null && true || echo "  (none)"

    echo ""
}

# ══════════════════════════════════════════
# Wave execution: full cleanup
# ══════════════════════════════════════════
cleanup_all() {
    print_status "═══ Pre-Wave: K8s Namespaces ═══"
    cleanup_k8s_namespaces

    # Wave 0: Peer account (multi-account only)
    if [[ "$MULTI_ACCOUNT" == "true" ]]; then
        print_status "═══ Wave 0: Peer Account Stacks ═══"

        # Reject PrivateLink connections before consumer deletion
        if [[ -n "$PROVIDER_SERVICES" ]]; then
            IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
            for svc in "${svc_list[@]}"; do
                local vpce_svc_id
                vpce_svc_id=$(get_stack_output "${PROJECT_NAME}-privatelink-provider-${svc}" "EndpointServiceId")
                reject_privatelink_connections "$vpce_svc_id"
            done
        fi

        # Delete peer stacks
        local peer_stacks=()
        if [[ -n "$PROVIDER_SERVICES" ]]; then
            IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
            for svc in "${svc_list[@]}"; do
                peer_stacks+=("${PEER_PROJECT}-privatelink-consumer-${svc}")
            done
        fi
        peer_stacks+=("${PEER_PROJECT}-devops-agent-xaccount")
        peer_stacks+=("${PEER_PROJECT}-dashboard-xaccount")

        for s in "${peer_stacks[@]}"; do
            delete_stack_async "$s" "peer"
        done
        wait_for_stacks "peer" "${peer_stacks[@]}"
    fi

    # Wave 1: Leaf stacks (no dependents)
    print_status "═══ Wave 1: Leaf Stacks ═══"
    local wave1_stacks=()

    if [[ -n "$PROVIDER_SERVICES" ]]; then
        IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
        for svc in "${svc_list[@]}"; do
            wave1_stacks+=("${PROJECT_NAME}-privatelink-provider-${svc}")
        done
    fi
    wave1_stacks+=(
        "${PROJECT_NAME}-security-role"
        "${PROJECT_NAME}-security-agent"
        "${PROJECT_NAME}-transaction-search"
        "${PROJECT_NAME}-github-actions"
        "${PROJECT_NAME}-fis"
    )

    for s in "${wave1_stacks[@]}"; do
        delete_stack_async "$s"
    done
    wait_for_stacks "" "${wave1_stacks[@]}"

    # Wave 2: Agent + RDS
    print_status "═══ Wave 2: Agent + RDS ═══"
    local wave2_stacks=("${PROJECT_NAME}-devops-agent" "${PROJECT_NAME}-rds-database")
    for s in "${wave2_stacks[@]}"; do
        delete_stack_async "$s"
    done
    wait_for_stacks "" "${wave2_stacks[@]}"

    # Wave 3: Alarms
    print_status "═══ Wave 3: Alarms ═══"
    delete_stack "${PROJECT_NAME}-alarms"

    # Wave 4: ECR + EKS Platform
    print_status "═══ Wave 4: ECR + EKS Platform ═══"
    force_delete_ecr_repos
    cleanup_eks_log_group
    delete_stack "${PROJECT_NAME}-eks-platform"

    # Wave 5: VPC Foundation
    print_status "═══ Wave 5: VPC Foundation ═══"
    local vpc_id
    vpc_id=$(get_stack_output "${PROJECT_NAME}-vpc-foundation" "VpcId")
    cleanup_orphaned_lbs "$vpc_id"
    cleanup_orphaned_enis "$vpc_id"
    cleanup_orphaned_sgs "$vpc_id"
    delete_stack "${PROJECT_NAME}-vpc-foundation"

    # Post: Secrets
    print_status "═══ Post: Secrets ═══"
    cleanup_secrets
}

# ══════════════════════════════════════════
# Unit-specific cleanup
# ══════════════════════════════════════════
cleanup_foundation() {
    print_status "═══ Unit: Foundation ═══"

    # Must delete agent stacks first (they import from foundation)
    # Check if agent stacks exist and block
    for dep_stack in "${PROJECT_NAME}-devops-agent" "${PROJECT_NAME}-security-agent"; do
        if stack_exists "$dep_stack"; then
            local status
            status=$(get_stack_status "$dep_stack")
            if [[ "$status" != "DELETE_COMPLETE" ]]; then
                print_error "Cannot delete foundation: $dep_stack still exists ($status)"
                print_error "Run: ./cleanup.sh --only agent first, or run without --only"
                exit 1
            fi
        fi
    done

    # Wave: fis, github-actions, alarms, rds in parallel
    local wave_stacks=(
        "${PROJECT_NAME}-fis"
        "${PROJECT_NAME}-github-actions"
        "${PROJECT_NAME}-alarms"
        "${PROJECT_NAME}-rds-database"
    )
    for s in "${wave_stacks[@]}"; do
        delete_stack_async "$s"
    done
    wait_for_stacks "" "${wave_stacks[@]}"

    # ECR + EKS
    force_delete_ecr_repos
    cleanup_eks_log_group
    delete_stack "${PROJECT_NAME}-eks-platform"

    # VPC
    local vpc_id
    vpc_id=$(get_stack_output "${PROJECT_NAME}-vpc-foundation" "VpcId")
    cleanup_orphaned_lbs "$vpc_id"
    cleanup_orphaned_enis "$vpc_id"
    cleanup_orphaned_sgs "$vpc_id"
    delete_stack "${PROJECT_NAME}-vpc-foundation"
}

cleanup_agent() {
    print_status "═══ Unit: Agent ═══"

    # Peer account stacks
    if [[ "$MULTI_ACCOUNT" == "true" ]]; then
        if [[ -n "$PROVIDER_SERVICES" ]]; then
            IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
            for svc in "${svc_list[@]}"; do
                local vpce_svc_id
                vpce_svc_id=$(get_stack_output "${PROJECT_NAME}-privatelink-provider-${svc}" "EndpointServiceId")
                reject_privatelink_connections "$vpce_svc_id"
            done
        fi

        local peer_stacks=("${PEER_PROJECT}-devops-agent-xaccount" "${PEER_PROJECT}-dashboard-xaccount")
        if [[ -n "$PROVIDER_SERVICES" ]]; then
            IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
            for svc in "${svc_list[@]}"; do
                peer_stacks+=("${PEER_PROJECT}-privatelink-consumer-${svc}")
            done
        fi
        for s in "${peer_stacks[@]}"; do
            delete_stack_async "$s" "peer"
        done
        wait_for_stacks "peer" "${peer_stacks[@]}"
    fi

    # Leaf agent stacks
    local leaf_stacks=(
        "${PROJECT_NAME}-security-role"
        "${PROJECT_NAME}-security-agent"
        "${PROJECT_NAME}-transaction-search"
    )
    if [[ -n "$PROVIDER_SERVICES" ]]; then
        IFS=',' read -ra svc_list <<< "$PROVIDER_SERVICES"
        for svc in "${svc_list[@]}"; do
            leaf_stacks+=("${PROJECT_NAME}-privatelink-provider-${svc}")
        done
    fi
    for s in "${leaf_stacks[@]}"; do
        delete_stack_async "$s"
    done
    wait_for_stacks "" "${leaf_stacks[@]}"

    # devops-agent
    delete_stack "${PROJECT_NAME}-devops-agent"
}

cleanup_test_app() {
    print_status "═══ Unit: Test App (K8s only) ═══"
    local cluster_name
    cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")

    if [[ -z "$cluster_name" || "$cluster_name" == "None" ]]; then
        print_warning "EKS cluster not found"
        return 0
    fi

    _aws eks update-kubeconfig --name "$cluster_name" --alias "$cluster_name" >/dev/null 2>&1 || true

    if kubectl get ns dockercoins --context "$cluster_name" >/dev/null 2>&1; then
        for svc in $(kubectl get svc -n dockercoins --context "$cluster_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            kubectl patch svc "$svc" -n dockercoins --context "$cluster_name" \
                -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
        kubectl delete namespace dockercoins --context "$cluster_name" --ignore-not-found
        print_status "✓ dockercoins namespace deleted"
    else
        print_warning "dockercoins namespace not found"
    fi
}

cleanup_dashboard() {
    print_status "═══ Unit: Dashboard (K8s + ECR) ═══"
    local cluster_name
    cluster_name=$(get_stack_output "${PROJECT_NAME}-eks-platform" "EKSClusterName")

    if [[ -n "$cluster_name" && "$cluster_name" != "None" ]]; then
        _aws eks update-kubeconfig --name "$cluster_name" --alias "$cluster_name" >/dev/null 2>&1 || true

        if kubectl get ns dashboard --context "$cluster_name" >/dev/null 2>&1; then
            for svc in $(kubectl get svc -n dashboard --context "$cluster_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                kubectl patch svc "$svc" -n dashboard --context "$cluster_name" \
                    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            done
            kubectl delete namespace dashboard --context "$cluster_name" --ignore-not-found
            print_status "✓ dashboard namespace deleted"
        else
            print_warning "dashboard namespace not found"
        fi
    fi

    # Dashboard ECR repo
    if _aws ecr describe-repositories --repository-names "${PROJECT_NAME}/dashboard" >/dev/null 2>&1; then
        print_status "Force-deleting ECR repo: ${PROJECT_NAME}/dashboard"
        _aws ecr delete-repository --repository-name "${PROJECT_NAME}/dashboard" --force >/dev/null 2>&1 || true
    fi
}

# ══════════════════════════════════════════
# Main
# ══════════════════════════════════════════
main() {
    echo ""
    print_status "=== Environment Cleanup ==="
    print_status "Project: $PROJECT_NAME"
    print_status "Profile: $AWS_PROFILE"
    print_status "Region:  $AWS_REGION"
    if [[ -n "$ONLY_UNIT" ]]; then
        print_status "Unit:    $ONLY_UNIT"
    fi
    if [[ "$MULTI_ACCOUNT" == "true" ]]; then
        print_status "Multi:   enabled (peer: $PEER_PROFILE / $PEER_PROJECT)"
    fi
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_report
        return 0
    fi

    # Confirmation
    if [[ "$FORCE" != "true" ]]; then
        echo -e "${RED}WARNING: This will permanently delete resources for project '${PROJECT_NAME}'.${NC}"
        echo -n "Are you sure? (yes/no): "
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    local account_id
    account_id=$(_aws sts get-caller-identity --query Account --output text)
    print_status "Account: $account_id"
    echo ""

    if [[ -n "$ONLY_UNIT" ]]; then
        case "$ONLY_UNIT" in
            foundation) cleanup_foundation ;;
            agent)      cleanup_agent ;;
            test-app)   cleanup_test_app ;;
            dashboard)  cleanup_dashboard ;;
            *)
                print_error "Unknown unit: $ONLY_UNIT"
                print_error "Valid units: foundation, agent, test-app, dashboard"
                exit 1 ;;
        esac
    else
        cleanup_all
    fi

    echo ""
    print_status "=== Cleanup Complete ==="

    # Show remaining stacks
    local remaining
    remaining=$(_aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
        --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}')].StackName" \
        --output text 2>/dev/null)

    if [[ -n "$remaining" && "$remaining" != "None" ]]; then
        print_warning "Remaining stacks:"
        for s in $remaining; do
            echo "  - $s"
        done
    else
        print_status "All stacks deleted successfully"
    fi
}

main "$@"
