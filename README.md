# Frontier Agent Test - DockerCoins

DockerCoins 테스트 대상 앱 + DevOps Agent 테스트용 인프라.

## 구조

```
services/dockercoins/   # DockerCoins 마이크로서비스 (hasher, rng, webui, worker)
infrastructure/
├── cloudformation/     # AWS CloudFormation 스택 (VPC, EKS, DevOps Agent, FIS 등)
├── kubernetes/         # K8s manifests (base + overlays)
└── *.sh               # 배포 스크립트
```

## 배포

```bash
# 전체 인프라 + 앱 배포
./infrastructure/deploy.sh

# DockerCoins만 배포
./infrastructure/deploy-dockercoins.sh
```
