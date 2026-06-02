#!/bin/bash
set -e

# Configuration
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
NAMESPACE="dockercoins"
OVERLAY_DIR="${SCRIPT_DIR}/kubernetes/dockercoins"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== DockerCoins EKS Deployment ===${NC}"

# Step 1: ECR Login
echo -e "${YELLOW}[1/5] ECR Login...${NC}"
aws ecr get-login-password --region ${AWS_REGION} --profile ${AWS_PROFILE} | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY}

# Step 2: Build and Push Images (x86_64)
echo -e "${YELLOW}[2/5] Building and pushing images (x86_64)...${NC}"

SERVICES=("hasher" "rng" "worker" "webui")
TAG=$(date +%Y%m%d-%H%M%S)

for SERVICE in "${SERVICES[@]}"; do
    echo -e "${GREEN}Building ${SERVICE}...${NC}"
    docker build --platform linux/amd64 -t ${ECR_REGISTRY}/${PROJECT_NAME}/${SERVICE}:${TAG} services/dockercoins/${SERVICE}/
    docker push ${ECR_REGISTRY}/${PROJECT_NAME}/${SERVICE}:${TAG}
done

# Step 3: Update kubeconfig
echo -e "${YELLOW}[3/5] Updating kubeconfig...${NC}"
aws eks update-kubeconfig --name ${PROJECT_NAME}-cluster --region ${AWS_REGION} --profile ${AWS_PROFILE}

# Step 4: Update kustomize overlay
echo -e "${YELLOW}[4/5] Updating kustomize overlay...${NC}"
cd "$OVERLAY_DIR"
for SERVICE in "${SERVICES[@]}"; do
    kustomize edit set image "${SERVICE}=${ECR_REGISTRY}/${PROJECT_NAME}/${SERVICE}:${TAG}"
done

# Step 5: Deploy via kustomize
echo -e "${YELLOW}[5/5] Deploying to Kubernetes...${NC}"
kubectl apply -k "$OVERLAY_DIR"

# Wait for pods
echo -e "${YELLOW}Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=available deployment --all -n ${NAMESPACE} --timeout=300s 2>/dev/null || true
kubectl get pods -n ${NAMESPACE}

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "Check status: kubectl get pods -n ${NAMESPACE}"
echo -e "Get WebUI URL: kubectl get svc webui -n ${NAMESPACE}"
