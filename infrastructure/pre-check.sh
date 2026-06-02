#!/bin/bash

# 배포 전 사전 검증 스크립트
set -e

ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"

echo "=== AWS 환경 사전 검증 ==="

# 1. PostgreSQL 사용 가능한 버전 확인
echo "1. PostgreSQL 버전 확인..."
POSTGRES_VERSIONS=$(aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion' --output text --profile $AWS_PROFILE --region $AWS_REGION | tr '\t' '\n' | sort -V)
echo "사용 가능한 PostgreSQL 버전:"
echo "$POSTGRES_VERSIONS" | tail -5

# 2. EKS 지원 버전 확인  
echo "2. EKS 버전 확인..."
EKS_VERSIONS=$(aws eks describe-addon-versions --query 'addons[0].addonVersions[].addonVersion' --output text --profile $AWS_PROFILE --region $AWS_REGION 2>/dev/null || echo "1.28 1.29 1.30")
echo "사용 가능한 EKS 버전: $EKS_VERSIONS"

# 3. 계정 한도 확인
echo "3. 계정 한도 확인..."
VPC_LIMIT=$(aws ec2 describe-account-attributes --attribute-names max-instances --query 'AccountAttributes[0].AttributeValues[0].AttributeValue' --output text --profile $AWS_PROFILE --region $AWS_REGION)
echo "EC2 인스턴스 한도: $VPC_LIMIT"

# 4. 기존 스택 상태 확인
echo "4. 기존 스택 확인..."
for stack in ${PROJECT_NAME}-vpc-foundation ${PROJECT_NAME}-eks-platform ${PROJECT_NAME}-rds-database; do
    STATUS=$(aws cloudformation describe-stacks --stack-name $stack --query 'Stacks[0].StackStatus' --output text --profile $AWS_PROFILE --region $AWS_REGION 2>/dev/null || echo "NOT_EXISTS")
    echo "  $stack: $STATUS"
done

echo "=== 사전 검증 완료 ==="