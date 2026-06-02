#!/bin/bash
# Usage: source "path/to/config/load-config.sh" <profile>
# Loads per-environment config and computes derived variables.

CONFIG_PROFILE="${1:?Usage: source load-config.sh <profile>}"
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_PROFILE}.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "  Copy ${CONFIG_DIR}/${CONFIG_PROFILE}.env.example → ${CONFIG_FILE} and fill in values"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Derived values (override in .env if needed)
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${PROJECT_NAME}-cluster}"
ECR_PREFIX="${ECR_REGISTRY}/${PROJECT_NAME}"
AWS_OPTS="--profile ${AWS_PROFILE} --region ${AWS_REGION} --no-cli-pager"
