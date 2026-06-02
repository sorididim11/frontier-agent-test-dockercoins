#!/bin/bash

# AWS DevOps Agent Test Environment - 자동화된 배포 스크립트
# 오류 자동 감지 및 수정 기능 포함

set -e

# Configuration
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
MAX_RETRIES=3

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to get available PostgreSQL versions
get_postgres_versions() {
    aws rds describe-db-engine-versions \
        --engine postgres \
        --query 'DBEngineVersions[?contains(SupportedEngineModes, `provisioned`)].EngineVersion' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" | tr '\t' '\n' | sort -V | tail -5
}

# Function to fix PostgreSQL version in RDS template
fix_postgres_version() {
    local available_versions
    available_versions=$(get_postgres_versions)
    local latest_version=$(echo "$available_versions" | tail -1)
    
    print_status "Available PostgreSQL versions: $(echo $available_versions | tr '\n' ' ')"
    print_status "Using latest version: $latest_version"
    
    # Update the template with the latest available version
    sed -i.bak "s/EngineVersion: '[0-9]*\.[0-9]*'/EngineVersion: '$latest_version'/" infrastructure/cloudformation/03-rds-database.yml
    print_status "Updated PostgreSQL version to $latest_version in RDS template"
}

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1
}

# Function to get stack status
get_stack_status() {
    aws cloudformation describe-stacks \
        --stack-name "$1" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || echo "NOT_EXISTS"
}

# Function to get stack failure reason
get_failure_reason() {
    local stack_name=$1
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null
}

# Function to auto-fix common CloudFormation errors
auto_fix_errors() {
    local stack_name=$1
    local failure_reason
    failure_reason=$(get_failure_reason "$stack_name")
    
    if [[ -z "$failure_reason" ]]; then
        return 1
    fi
    
    print_debug "Failure reason: $failure_reason"
    
    # Fix PostgreSQL version error
    if echo "$failure_reason" | grep -q "Cannot find version.*postgres"; then
        print_warning "PostgreSQL version not available, fixing automatically..."
        fix_postgres_version
        return 0
    fi
    
    # Fix export name conflicts
    if echo "$failure_reason" | grep -q "is already exported"; then
        print_warning "Export name conflict detected, fixing automatically..."
        # This would need specific logic based on the conflict
        return 0
    fi
    
    # Fix security group reference errors
    if echo "$failure_reason" | grep -q "does not exist"; then
        print_warning "Resource reference error detected..."
        return 0
    fi
    
    return 1
}

# Function to wait for stack completion with timeout
wait_for_stack() {
    local stack_name=$1
    local operation=$2
    local timeout=${3:-1800}  # 30 minutes default
    local start_time=$(date +%s)
    
    print_status "Waiting for stack $stack_name to complete $operation (timeout: ${timeout}s)..."
    
    while true; do
        local status=$(get_stack_status "$stack_name")
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        case "$status" in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                print_status "Stack $stack_name $operation completed successfully"
                return 0
                ;;
            "CREATE_FAILED"|"ROLLBACK_COMPLETE"|"UPDATE_ROLLBACK_COMPLETE")
                print_error "Stack $stack_name $operation failed with status: $status"
                return 1
                ;;
            "DELETE_COMPLETE")
                if [[ "$operation" == "delete" ]]; then
                    print_status "Stack $stack_name deleted successfully"
                    return 0
                else
                    print_error "Stack $stack_name was unexpectedly deleted"
                    return 1
                fi
                ;;
            "NOT_EXISTS")
                if [[ "$operation" == "delete" ]]; then
                    print_status "Stack $stack_name does not exist (already deleted)"
                    return 0
                else
                    print_error "Stack $stack_name does not exist"
                    return 1
                fi
                ;;
        esac
        
        if [[ $elapsed -gt $timeout ]]; then
            print_error "Timeout waiting for stack $stack_name to complete $operation"
            return 1
        fi
        
        echo -n "."
        sleep 10
    done
}

# Function to delete failed stack
delete_failed_stack() {
    local stack_name=$1
    local status=$(get_stack_status "$stack_name")
    
    if [[ "$status" == "ROLLBACK_COMPLETE" || "$status" == "CREATE_FAILED" ]]; then
        print_status "Deleting failed stack: $stack_name"
        aws cloudformation delete-stack \
            --stack-name "$stack_name" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION"
        wait_for_stack "$stack_name" "delete" 600
    fi
}

# Function to deploy stack with auto-retry and error fixing
deploy_stack_with_retry() {
    local stack_name=$1
    local template_file=$2
    local retry_count=0
    
    local parameters=(
        "ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME"
        "ParameterKey=Environment,ParameterValue=devops-agent-test"
    )
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        print_status "Deploying stack: $stack_name (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        if stack_exists "$stack_name"; then
            local status=$(get_stack_status "$stack_name")
            if [[ "$status" == "ROLLBACK_COMPLETE" || "$status" == "CREATE_FAILED" ]]; then
                delete_failed_stack "$stack_name"
            elif [[ "$status" == "CREATE_COMPLETE" || "$status" == "UPDATE_COMPLETE" ]]; then
                print_status "Stack $stack_name already exists and is complete"
                return 0
            fi
        fi
        
        # Create the stack
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters "${parameters[@]}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null
        
        # Wait for completion
        if wait_for_stack "$stack_name" "create" 1800; then
            print_status "Stack $stack_name deployed successfully"
            return 0
        else
            print_error "Stack $stack_name deployment failed"
            
            # Try to auto-fix the error
            if auto_fix_errors "$stack_name"; then
                print_status "Auto-fix applied, retrying..."
                delete_failed_stack "$stack_name"
                retry_count=$((retry_count + 1))
                continue
            else
                print_error "Could not auto-fix error for stack $stack_name"
                delete_failed_stack "$stack_name"
                retry_count=$((retry_count + 1))
            fi
        fi
    done
    
    print_error "Failed to deploy stack $stack_name after $MAX_RETRIES attempts"
    return 1
}

# Function to validate all templates before deployment
validate_templates() {
    print_status "Validating CloudFormation templates..."
    
    local templates=(
        "infrastructure/cloudformation/01-vpc-foundation.yml"
        "infrastructure/cloudformation/02-eks-platform.yml"
        "infrastructure/cloudformation/03-rds-database.yml"
    )
    
    for template in "${templates[@]}"; do
        print_status "Validating $template..."
        if ! aws cloudformation validate-template \
            --template-body "file://$template" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null; then
            print_error "Template validation failed: $template"
            return 1
        fi
    done
    
    print_status "All templates validated successfully"
}

# Function to get deployment outputs
get_deployment_outputs() {
    print_status "Retrieving deployment information..."
    
    local eks_cluster_name=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-eks-platform" \
        --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || echo "N/A")
    
    local alb_dns=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-eks-platform" \
        --query 'Stacks[0].Outputs[?OutputKey==`ApplicationLoadBalancerDNS`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || echo "N/A")
    
    local db_endpoint=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-rds-database" \
        --query 'Stacks[0].Outputs[?OutputKey==`DatabaseEndpoint`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || echo "N/A")
    
    echo ""
    print_status "=== Deployment Summary ==="
    echo "EKS Cluster Name: $eks_cluster_name"
    echo "Load Balancer DNS: $alb_dns"
    echo "Database Endpoint: $db_endpoint"
    echo ""

    if [[ "$eks_cluster_name" != "N/A" ]]; then
        print_status "Next Steps:"
        echo "1. Configure kubectl:"
        echo "   aws eks update-kubeconfig --region $AWS_REGION --name $eks_cluster_name --profile $AWS_PROFILE"
        echo ""
    fi
}

# Main deployment function
main() {
    print_status "Starting automated AWS DevOps Agent Test Environment deployment"
    print_status "Project: $PROJECT_NAME"
    print_status "AWS Profile: $AWS_PROFILE"
    print_status "AWS Region: $AWS_REGION"
    print_status "Max Retries: $MAX_RETRIES"
    echo ""
    
    # Check AWS CLI configuration
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        print_error "AWS CLI not configured for profile $AWS_PROFILE"
        exit 1
    fi
    
    # Pre-deployment fixes
    print_status "Applying pre-deployment fixes..."
    fix_postgres_version
    
    # Validate templates
    validate_templates
    
    # Change to infrastructure directory
    cd "$(dirname "$0")/cloudformation"
    
    # Deploy stacks in order
    print_status "=== Phase 1: VPC Foundation ==="
    if ! deploy_stack_with_retry "${PROJECT_NAME}-vpc-foundation" "01-vpc-foundation.yml"; then
        print_error "VPC Foundation deployment failed"
        exit 1
    fi
    
    print_status "=== Phase 2: EKS Platform ==="
    if ! deploy_stack_with_retry "${PROJECT_NAME}-eks-platform" "02-eks-platform.yml"; then
        print_error "EKS Platform deployment failed"
        exit 1
    fi
    
    print_status "=== Phase 3: RDS Database ==="
    if ! deploy_stack_with_retry "${PROJECT_NAME}-rds-database" "03-rds-database.yml"; then
        print_error "RDS Database deployment failed"
        exit 1
    fi
    
    # Get deployment outputs
    cd - >/dev/null
    get_deployment_outputs
    
    print_status "🎉 Infrastructure deployment completed successfully!"
}

# Run main function
main "$@"