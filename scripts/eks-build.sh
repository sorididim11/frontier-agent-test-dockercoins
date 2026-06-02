#!/bin/bash
# EKS Kaniko 빌드: 로컬 Docker 없이 EKS에서 직접 빌드 + ECR push + 배포
# GitHub Actions와 동일한 버전닝 (git sha + kustomize edit set image)
set -e

SERVICE="${1:-dashboard}"
ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"
REGISTRY="$ECR_REGISTRY"
PROJECT="$PROJECT_NAME"
BUILD_NS="build"
TAG=$(git rev-parse --short HEAD)

# 서비스별 context/kustomize 경로
case $SERVICE in
  dashboard) CONTEXT="services/dashboard"; DEPLOY_NS="dashboard"; KUSTOMIZE_DIR="infrastructure/kubernetes/dashboard" ;;
  hasher)    CONTEXT="services/dockercoins/hasher"; DEPLOY_NS="dockercoins"; KUSTOMIZE_DIR="infrastructure/kubernetes/dockercoins" ;;
  rng)       CONTEXT="services/dockercoins/rng"; DEPLOY_NS="dockercoins"; KUSTOMIZE_DIR="infrastructure/kubernetes/dockercoins" ;;
  worker)    CONTEXT="services/dockercoins/worker"; DEPLOY_NS="dockercoins"; KUSTOMIZE_DIR="infrastructure/kubernetes/dockercoins" ;;
  webui)     CONTEXT="services/dockercoins/webui"; DEPLOY_NS="dockercoins"; KUSTOMIZE_DIR="infrastructure/kubernetes/dockercoins" ;;
  *) echo "❌ Unknown service: $SERVICE"; exit 1 ;;
esac

REPO="$PROJECT/$SERVICE"
IMAGE="$REGISTRY/$REPO:$TAG"

echo "🏗️  EKS 빌드: $SERVICE → $IMAGE"

# 1. 인프라 확인/생성
kubectl get ns $BUILD_NS >/dev/null 2>&1 || kubectl apply -f infrastructure/kubernetes/build/kaniko-build.yaml

# 2. 빌드 context를 ConfigMap으로 전송
echo "📦 빌드 context 패키징..."
tar -czf /tmp/build-context.tar.gz -C $CONTEXT .
kubectl delete configmap build-context -n $BUILD_NS 2>/dev/null || true
kubectl create configmap build-context -n $BUILD_NS --from-file=context.tar.gz=/tmp/build-context.tar.gz

# 3. Kaniko 빌드 pod 실행
echo "🚀 Kaniko 빌드 시작..."
kubectl delete pod kaniko-build -n $BUILD_NS --ignore-not-found=true 2>/dev/null
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
  namespace: $BUILD_NS
spec:
  serviceAccountName: kaniko-builder
  restartPolicy: Never
  initContainers:
  - name: unpack
    image: busybox
    command: ["/bin/sh", "-c", "tar -xzf /context-cm/context.tar.gz -C /workspace"]
    volumeMounts:
    - name: context-cm
      mountPath: /context-cm
    - name: workspace
      mountPath: /workspace
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:latest
    args:
    - "--dockerfile=Dockerfile"
    - "--context=dir:///workspace"
    - "--destination=$IMAGE"
    - "--cache=true"
    - "--cache-dir=/cache"
    - "--cache-repo=$REGISTRY/$REPO/cache"
    - "--snapshot-mode=redo"
    - "--compressed-caching=false"
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    - name: cache
      mountPath: /cache
  volumes:
  - name: context-cm
    configMap:
      name: build-context
  - name: workspace
    emptyDir: {}
  - name: cache
    persistentVolumeClaim:
      claimName: kaniko-cache
EOF

# 4. 빌드 완료 대기
echo "⏳ 빌드 대기..."
kubectl wait --for=condition=Ready pod/kaniko-build -n $BUILD_NS --timeout=30s 2>/dev/null || true
kubectl logs -f kaniko-build -n $BUILD_NS -c kaniko 2>/dev/null &
LOG_PID=$!
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/kaniko-build -n $BUILD_NS --timeout=300s
kill $LOG_PID 2>/dev/null || true

echo "✅ 빌드 완료: $IMAGE"

# 5. 배포 (Actions와 동일: kustomize edit set image)
echo "🚀 배포: $SERVICE"
pushd $KUSTOMIZE_DIR > /dev/null
kubectl kustomize edit set image $REGISTRY/$REPO=$IMAGE 2>/dev/null || \
  sed -i '' "s|newTag:.*|newTag: \"$TAG\"|" kustomization.yaml
popd > /dev/null
kubectl apply -k $KUSTOMIZE_DIR

# 6. pod 삭제로 즉시 교체
kubectl delete pod -n $DEPLOY_NS -l app=$SERVICE --wait=false 2>/dev/null || true
kubectl wait --for=condition=ready pod -n $DEPLOY_NS -l app=$SERVICE --timeout=60s

DEPLOYED=$(kubectl get deployment $SERVICE -n $DEPLOY_NS -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
echo "✅ 배포 완료: $DEPLOYED"

# 정리
kubectl delete pod kaniko-build -n $BUILD_NS --ignore-not-found=true 2>/dev/null
rm -f /tmp/build-context.tar.gz
