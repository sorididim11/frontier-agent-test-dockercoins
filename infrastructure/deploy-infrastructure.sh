#!/bin/bash

# AWS DevOps Agent Test Environment - Infrastructure Deployment Script
# This script deploys the complete infrastructure using CloudFormation

set -e

# Configuration
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks --stack-name "$1" --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1
}

# Function to wait for stack completion
wait_for_stack() {
    local stack_name=$1
    local operation=$2
    
    print_status "Waiting for stack $stack_name to complete $operation..."
    
    aws cloudformation wait "stack-${operation}-complete" \
        --stack-name "$stack_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION"
    
    if [ $? -eq 0 ]; then
        print_status "Stack $stack_name $operation completed successfully"
    else
        print_error "Stack $stack_name $operation failed"
        exit 1
    fi
}

# Function to deploy stack
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    
    print_status "Deploying stack: $stack_name"
    
    local parameters=(
        "ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME"
        "ParameterKey=Environment,ParameterValue=devops-agent-test"
    )
    
    if stack_exists "$stack_name"; then
        print_warning "Stack $stack_name already exists, updating..."
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters "${parameters[@]}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" || {
                if [[ $? -eq 254 ]]; then
                    print_warning "No updates to be performed for stack $stack_name"
                    return 0
                else
                    print_error "Failed to update stack $stack_name"
                    exit 1
                fi
            }
        wait_for_stack "$stack_name" "update"
    else
        print_status "Creating new stack: $stack_name"
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters "${parameters[@]}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION"
        wait_for_stack "$stack_name" "create"
    fi
}

# Main deployment function
main() {
    print_status "Starting AWS DevOps Agent Test Environment deployment"
    print_status "Project: $PROJECT_NAME"
    print_status "AWS Profile: $AWS_PROFILE"
    print_status "AWS Region: $AWS_REGION"
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        print_error "AWS CLI not configured for profile $AWS_PROFILE"
        exit 1
    fi
    
    # Change to infrastructure directory
    cd "$(dirname "$0")/cloudformation"
    
    # Deploy VPC Foundation
    print_status "Step 1: Deploying VPC Foundation..."
    deploy_stack \
        "${PROJECT_NAME}-vpc-foundation" \
        "01-vpc-foundation.yml"
    
    # Deploy EKS Platform
    print_status "Step 2: Deploying EKS Platform..."
    deploy_stack \
        "${PROJECT_NAME}-eks-platform" \
        "02-eks-platform.yml"
    
    # Deploy RDS Database
    print_status "Step 3: Deploying RDS Database..."
    deploy_stack \
        "${PROJECT_NAME}-rds-database" \
        "03-rds-database.yml"
    
    print_status "Infrastructure deployment completed successfully!"
    
    # Get important outputs
    print_status "Retrieving deployment information..."
    
    EKS_CLUSTER_NAME=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-eks-platform" \
        --query 'Stacks[0].Outputs[?OutputKey==`EKSClusterName`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION")
    
    ALB_DNS=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-eks-platform" \
        --query 'Stacks[0].Outputs[?OutputKey==`ApplicationLoadBalancerDNS`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION")
    
    DB_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-rds-database" \
        --query 'Stacks[0].Outputs[?OutputKey==`DatabaseEndpoint`].OutputValue' \
        --output text \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION")
    
    print_status "Deployment Summary:"
    echo "===================="
    echo "EKS Cluster Name: $EKS_CLUSTER_NAME"
    echo "Load Balancer DNS: $ALB_DNS"
    echo "Database Endpoint: $DB_ENDPOINT"
    echo ""

    print_status "Next Steps:"
    echo "1. Configure kubectl for EKS cluster:"
    echo "   aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME --profile $AWS_PROFILE"
    echo ""
    echo "2. Install AWS Load Balancer Controller:"
    echo "   kubectl apply -f ../kubernetes/aws-load-balancer-controller.yaml"
    echo ""
    
    print_status "Infrastructure is ready for DevOps Agent testing!"
}

# Run main function
main "$@"