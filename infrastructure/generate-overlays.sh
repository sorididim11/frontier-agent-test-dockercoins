#!/bin/bash
# Generate K8s overlay kustomization.yaml files from templates + config.
# Usage: ./generate-overlays.sh <profile> [--tag <image-tag>]
#
# Looks up RDS endpoint from CloudFormation, fills templates, writes output.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/config/load-config.sh" "${1:?Usage: $0 <profile> [--tag <tag>]}"

IMAGE_TAG="latest"
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag) IMAGE_TAG="$2"; shift 2 ;;
        *) shift ;;
    esac
done

OVERLAY_DIR="${SCRIPT_DIR}/kubernetes/overlays/${AWS_PROFILE}"
TMPL_DIR="${SCRIPT_DIR}/kubernetes/overlays"

RDS_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-rds-database" \
    --query 'Stacks[0].Outputs[?OutputKey==`DatabaseEndpoint`].OutputValue' \
    --output text $AWS_OPTS 2>/dev/null || echo "__RDS_ENDPOINT_NOT_FOUND__")

CLEANUP_ROLE_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-eks-platform" \
    --query 'Stacks[0].Outputs[?OutputKey==`CleanupServiceIAMRoleArn`].OutputValue' \
    --output text $AWS_OPTS 2>/dev/null || echo "__CLEANUP_ROLE_ARN_NOT_FOUND__")

export ECR_PREFIX AWS_ACCOUNT_ID PROJECT_NAME RDS_ENDPOINT CLEANUP_ROLE_ARN
export HASHER_TAG="${HASHER_TAG:-$IMAGE_TAG}"
export RNG_TAG="${RNG_TAG:-$IMAGE_TAG}"
export WORKER_TAG="${WORKER_TAG:-$IMAGE_TAG}"
export WEBUI_TAG="${WEBUI_TAG:-$IMAGE_TAG}"
export DASHBOARD_TAG="${DASHBOARD_TAG:-$IMAGE_TAG}"

mkdir -p "${OVERLAY_DIR}/dockercoins" "${OVERLAY_DIR}/dashboard"

envsubst < "${TMPL_DIR}/dockercoins-kustomization.yaml.tmpl" > "${OVERLAY_DIR}/dockercoins/kustomization.yaml"
envsubst < "${TMPL_DIR}/dashboard-kustomization.yaml.tmpl" > "${OVERLAY_DIR}/dashboard/kustomization.yaml"

echo "Generated overlays for ${AWS_PROFILE} (${PROJECT_NAME}):"
echo "  ${OVERLAY_DIR}/dockercoins/kustomization.yaml"
echo "  ${OVERLAY_DIR}/dashboard/kustomization.yaml"
echo "  RDS endpoint: ${RDS_ENDPOINT}"
echo "  Image tag: ${IMAGE_TAG}"
