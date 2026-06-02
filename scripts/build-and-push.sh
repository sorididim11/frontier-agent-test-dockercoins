#!/bin/bash
# Build and push Docker images with git-based versioning
# Usage: ./scripts/build-and-push.sh [service] [--push]
#   service: hasher, rng, webui, worker, all (default: all)
#   --push: push to ECR after build

set -e

# Configuration
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
ECR_REPO="${ECR_PREFIX}"
DOCKER_HOST_AMD64="unix://${HOME}/.colima/amd64/docker.sock"

# Get version from git
get_version() {
    local git_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local git_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")
    local git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    if [ -n "$git_tag" ]; then
        echo "$git_tag"
    else
        echo "${git_branch}-${git_hash}-${timestamp}"
    fi
}

# Build single service
build_service() {
    local service=$1
    local version=$2
    local push=$3
    local service_dir="services/dockercoins/${service}"
    
    if [ ! -d "$service_dir" ]; then
        echo "ERROR: Service directory not found: $service_dir"
        return 1
    fi
    
    echo "=== Building ${service} ==="
    echo "Version: ${version}"
    
    # Set Docker host for x86_64 builds
    export DOCKER_HOST="$DOCKER_HOST_AMD64"
    
    # Build image
    docker build --platform linux/amd64 \
        -t "${service}:${version}" \
        -t "${service}:latest" \
        "$service_dir"
    
    if [ "$push" = "true" ]; then
        echo "=== Pushing ${service} to ECR ==="
        
        # Tag for ECR
        docker tag "${service}:${version}" "${ECR_REPO}/${service}:${version}"
        docker tag "${service}:latest" "${ECR_REPO}/${service}:latest"
        
        # Push both tags
        docker push "${ECR_REPO}/${service}:${version}"
        docker push "${ECR_REPO}/${service}:latest"
        
        echo "Pushed: ${ECR_REPO}/${service}:${version}"
    fi
    
    echo "=== ${service} build complete ==="
    echo ""
}

# ECR login
ecr_login() {
    echo "=== Logging into ECR ==="
    aws ecr get-login-password --region ${AWS_REGION} --profile ${AWS_PROFILE} | \
        docker login --username AWS --password-stdin ${ECR_REGISTRY}
}

# Main
main() {
    local service="${1:-all}"
    local push="false"
    
    # Check for --push flag
    for arg in "$@"; do
        if [ "$arg" = "--push" ]; then
            push="true"
        fi
    done
    
    # Get version
    local version=$(get_version)
    echo "Build version: ${version}"
    echo ""
    
    # ECR login if pushing
    if [ "$push" = "true" ]; then
        ecr_login
    fi
    
    # Build services
    case "$service" in
        hasher|rng|webui|worker)
            build_service "$service" "$version" "$push"
            ;;
        all)
            for svc in hasher rng webui worker; do
                if [ -d "services/dockercoins/${svc}" ]; then
                    build_service "$svc" "$version" "$push"
                fi
            done
            ;;
        *)
            echo "Usage: $0 [hasher|rng|webui|worker|all] [--push]"
            exit 1
            ;;
    esac
    
    echo "=== All builds complete ==="
    echo "Version: ${version}"
    
    # Save version to file for reference
    echo "$version" > .build-version
}

main "$@"
