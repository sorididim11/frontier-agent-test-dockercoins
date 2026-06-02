#!/bin/bash
# ============================================
# DevOps Agent Test Scenario Trigger Script
# ============================================
# Usage: ./trigger-scenarios.sh <scenario-number>
#
# Scenarios:
#   1 - OOMKilled (hasher /oom endpoint)
#   2 - ImagePullBackOff (deploy with wrong image tag)
#   3 - CrashLoopBackOff (app startup failure)
#   4 - High Latency (hasher /slow endpoint)
#   5 - Resource Quota Exceeded
#   6 - Service Discovery Failure
#   7 - HTTP 500 Errors (hasher /error endpoint)
#   8 - CPU Spike (rng /cpu endpoint)
#   9 - Dependency Failure (rng /dependency-fail endpoint)
#   cleanup - Remove all test deployments

ENV_PROFILE="${ENV_PROFILE:-member1-acc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config/load-config.sh" "$ENV_PROFILE"

NAMESPACE="dockercoins"

case "$1" in
  1|oom)
    echo "=== Scenario 1: OOMKilled ==="
    echo "Triggering OOM on hasher service..."
    kubectl run oom-trigger --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://hasher/oom --max-time 60 2>/dev/null || true
    echo ""
    echo "Check pod status:"
    kubectl get pods -n $NAMESPACE -l app=hasher
    kubectl describe pod -n $NAMESPACE -l app=hasher | grep -A5 "Last State:"
    ;;

  2|imagepull)
    echo "=== Scenario 2: ImagePullBackOff ==="
    echo "Deploying pod with non-existent image tag..."
    kubectl apply -f kubernetes/dockercoins/test-scenarios.yaml -l scenario=imagepullbackoff -n $NAMESPACE 2>/dev/null || \
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-imagepull-fail
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-imagepull-fail
  template:
    metadata:
      labels:
        app: test-imagepull-fail
    spec:
      containers:
      - name: test-container
        image: ${ECR_PREFIX}/hasher:nonexistent-v999
        imagePullPolicy: Always
EOF
    sleep 5
    echo ""
    echo "Check pod status (should show ImagePullBackOff):"
    kubectl get pods -n $NAMESPACE -l app=test-imagepull-fail
    kubectl describe pod -n $NAMESPACE -l app=test-imagepull-fail | grep -A10 "Events:"
    ;;

  3|crashloop)
    echo "=== Scenario 3: CrashLoopBackOff ==="
    echo "Deploying pod that crashes on startup..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-crashloop
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-crashloop
  template:
    metadata:
      labels:
        app: test-crashloop
    spec:
      containers:
      - name: test-container
        image: busybox:latest
        command: ["sh", "-c", "echo 'ERROR: Missing required configuration DB_HOST' && exit 1"]
EOF
    echo "Waiting for CrashLoopBackOff..."
    sleep 30
    echo ""
    echo "Check pod status (should show CrashLoopBackOff):"
    kubectl get pods -n $NAMESPACE -l app=test-crashloop
    kubectl logs -n $NAMESPACE -l app=test-crashloop --tail=10
    ;;

  4|latency)
    echo "=== Scenario 4: High Latency ==="
    echo "Triggering slow responses on hasher (5 second delay)..."
    for i in {1..10}; do
      kubectl run latency-test-$i --image=curlimages/curl --rm --restart=Never -n $NAMESPACE \
        -- curl -s http://hasher/slow?delay=5 --max-time 10 &
    done
    wait
    echo "Latency test completed. Check CloudWatch alarms."
    ;;

  5|quota)
    echo "=== Scenario 5: Resource Quota Exceeded ==="
    echo "Applying restrictive resource quota..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: test-restrictive-quota
  namespace: $NAMESPACE
spec:
  hard:
    requests.memory: "64Mi"
    limits.memory: "128Mi"
EOF
    echo ""
    echo "Trying to deploy pod that exceeds quota..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-quota-exceed
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-quota-exceed
  template:
    metadata:
      labels:
        app: test-quota-exceed
    spec:
      containers:
      - name: test-container
        image: nginx:alpine
        resources:
          requests:
            memory: "256Mi"
          limits:
            memory: "512Mi"
EOF
    sleep 5
    echo ""
    echo "Check deployment status:"
    kubectl get deployment test-quota-exceed -n $NAMESPACE
    kubectl describe deployment test-quota-exceed -n $NAMESPACE | grep -A5 "Conditions:"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -5
    ;;

  6|servicediscovery)
    echo "=== Scenario 6: Service Discovery Failure ==="
    echo "Deploying pod that tries to connect to non-existent service..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-service-discovery
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-service-discovery
  template:
    metadata:
      labels:
        app: test-service-discovery
    spec:
      containers:
      - name: test-container
        image: curlimages/curl:latest
        command: ["sh", "-c", "while true; do echo 'Trying to connect to backend...'; curl -s --max-time 5 http://nonexistent-backend.dockercoins:8080/ || echo 'FAILED: Service not found'; sleep 5; done"]
EOF
    sleep 10
    echo ""
    echo "Check pod logs:"
    kubectl logs -n $NAMESPACE -l app=test-service-discovery --tail=10
    ;;

  7|error)
    echo "=== Scenario 7: HTTP 500 Errors ==="
    echo "Triggering HTTP 500 errors on hasher..."
    for i in {1..20}; do
      kubectl run error-test-$i --image=curlimages/curl --rm --restart=Never -n $NAMESPACE \
        -- curl -s http://hasher/error &
    done
    wait
    echo "Error generation completed. Check CloudWatch alarms."
    ;;

  8|cpu)
    echo "=== Scenario 8: CPU Spike ==="
    echo "Triggering CPU spike on rng service (60 seconds)..."
    kubectl run cpu-trigger --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/cpu?duration=60 --max-time 70 || true
    echo "CPU spike completed."
    ;;

  9|dependency)
    echo "=== Scenario 9: Dependency Failure ==="
    echo "Triggering dependency failure on rng..."
    kubectl run dep-trigger --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/dependency-fail || true
    ;;

  10|networkpolicy)
    echo "=== Scenario K07: NetworkPolicy Block ==="
    echo "Deploying NetworkPolicy that blocks all ingress..."
    kubectl apply -f kubernetes/dockercoins/test-scenarios.yaml -l scenario=networkpolicy-block -n $NAMESPACE 2>/dev/null || \
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-deny-all-ingress
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      network-test: blocked
  policyTypes:
  - Ingress
  ingress: []
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-network-blocked
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-network-blocked
  template:
    metadata:
      labels:
        app: test-network-blocked
        network-test: blocked
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-network-blocked
  namespace: $NAMESPACE
spec:
  selector:
    app: test-network-blocked
  ports:
  - port: 80
EOF
    sleep 10
    echo ""
    echo "Testing connection (should timeout):"
    kubectl run net-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s --max-time 5 http://test-network-blocked/ || echo "Connection blocked by NetworkPolicy (expected)"
    ;;

  11|pvc)
    echo "=== Scenario K06: PVC Binding Failure ==="
    echo "Creating PVC with non-existent StorageClass..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-fail
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nonexistent-storage-class
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-pvc-pending
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-pvc-pending
  template:
    metadata:
      labels:
        app: test-pvc-pending
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "sleep 3600"]
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: test-pvc-fail
EOF
    sleep 5
    echo ""
    echo "PVC Status (should be Pending):"
    kubectl get pvc test-pvc-fail -n $NAMESPACE
    echo ""
    echo "Pod Status (should be Pending):"
    kubectl get pods -n $NAMESPACE -l app=test-pvc-pending
    ;;

  12|hpa)
    echo "=== Scenario K08: HPA Scaling Failure ==="
    echo "Creating HPA with non-existent metric..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-hpa-target
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-hpa-target
  template:
    metadata:
      labels:
        app: test-hpa-target
    spec:
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            cpu: "50m"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: test-hpa-fail
  namespace: $NAMESPACE
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: test-hpa-target
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Pods
    pods:
      metric:
        name: nonexistent_custom_metric
      target:
        type: AverageValue
        averageValue: "100"
EOF
    sleep 10
    echo ""
    echo "HPA Status (should show unable to fetch metrics):"
    kubectl get hpa test-hpa-fail -n $NAMESPACE
    kubectl describe hpa test-hpa-fail -n $NAMESPACE | grep -A5 "Conditions:"
    ;;

  13|configmap)
    echo "=== Scenario: ConfigMap Missing ==="
    echo "Creating pod that references non-existent ConfigMap..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-configmap-missing
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-configmap-missing
  template:
    metadata:
      labels:
        app: test-configmap-missing
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "echo \$APP_CONFIG && sleep 3600"]
        env:
        - name: APP_CONFIG
          valueFrom:
            configMapKeyRef:
              name: nonexistent-configmap
              key: config
EOF
    sleep 5
    echo ""
    echo "Pod Status (should show CreateContainerConfigError):"
    kubectl get pods -n $NAMESPACE -l app=test-configmap-missing
    kubectl describe pod -n $NAMESPACE -l app=test-configmap-missing | grep -A5 "Events:"
    ;;

  14|secret)
    echo "=== Scenario: Secret Missing ==="
    echo "Creating pod that references non-existent Secret..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-secret-missing
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-secret-missing
  template:
    metadata:
      labels:
        app: test-secret-missing
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "echo \$DB_PASSWORD && sleep 3600"]
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nonexistent-secret
              key: password
EOF
    sleep 5
    echo ""
    echo "Pod Status (should show CreateContainerConfigError):"
    kubectl get pods -n $NAMESPACE -l app=test-secret-missing
    ;;

  15|liveness)
    echo "=== Scenario: Liveness Probe Failure ==="
    echo "Creating pod with failing liveness probe..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-liveness-fail
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-liveness-fail
  template:
    metadata:
      labels:
        app: test-liveness-fail
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "sleep 3600"]
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 3
EOF
    echo "Waiting for liveness probe failures..."
    sleep 30
    echo ""
    echo "Pod Status (should show restarts due to liveness failure):"
    kubectl get pods -n $NAMESPACE -l app=test-liveness-fail
    kubectl describe pod -n $NAMESPACE -l app=test-liveness-fail | grep -A10 "Events:"
    ;;

  16|readiness)
    echo "=== Scenario: Readiness Probe Failure ==="
    echo "Creating pod with failing readiness probe..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-readiness-fail
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-readiness-fail
  template:
    metadata:
      labels:
        app: test-readiness-fail
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /nonexistent-health-endpoint
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: test-readiness-fail
  namespace: $NAMESPACE
spec:
  selector:
    app: test-readiness-fail
  ports:
  - port: 80
EOF
    sleep 15
    echo ""
    echo "Pod Status (should show 0/1 Ready):"
    kubectl get pods -n $NAMESPACE -l app=test-readiness-fail
    echo ""
    echo "Endpoints (should be empty):"
    kubectl get endpoints test-readiness-fail -n $NAMESPACE
    ;;

  # ============================================
  # AWS Infrastructure Layer Scenarios
  # ============================================

  20|sg-block)
    echo "=== Scenario I02: Security Group Block ==="
    echo "WARNING: This will temporarily block RDS access from EKS"
    echo ""
    
    # Get Security Group ID
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=devops-agent-test-db-sg" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
      echo "ERROR: Could not find RDS Security Group"
      exit 1
    fi
    
    echo "RDS Security Group: $SG_ID"
    echo ""
    echo "Current ingress rules:"
    aws ec2 describe-security-groups --group-ids $SG_ID \
      --query 'SecurityGroups[0].IpPermissions' \
      --output table \
      $AWS_OPTS
    
    echo ""
    echo "Revoking PostgreSQL access from private subnets..."
    
    # Revoke access (this will cause DB connection failures)
    aws ec2 revoke-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.11.0/24 \
      $AWS_OPTS 2>/dev/null || echo "Rule 10.0.11.0/24 not found"
    
    aws ec2 revoke-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.12.0/24 \
      $AWS_OPTS 2>/dev/null || echo "Rule 10.0.12.0/24 not found"
    
    echo ""
    echo "Security Group rules revoked. DB connections will now fail."
    echo "To restore, run: $0 sg-restore"
    ;;

  21|sg-restore)
    echo "=== Restoring Security Group Rules ==="
    
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=devops-agent-test-db-sg" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      $AWS_OPTS)
    
    echo "Restoring PostgreSQL access rules..."
    
    aws ec2 authorize-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.11.0/24 \
      $AWS_OPTS 2>/dev/null || echo "Rule already exists"
    
    aws ec2 authorize-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.12.0/24 \
      $AWS_OPTS 2>/dev/null || echo "Rule already exists"
    
    echo "Security Group rules restored."
    ;;

  22|rds-connection)
    echo "=== Scenario I01: RDS Connection Test ==="
    echo "Testing database connectivity from EKS..."
    
    # Get RDS endpoint
    RDS_ENDPOINT=$(aws rds describe-db-instances \
      --db-instance-identifier devops-agent-test-database \
      --query 'DBInstances[0].Endpoint.Address' \
      --output text \
      $AWS_OPTS)
    
    echo "RDS Endpoint: $RDS_ENDPOINT"
    
    # Test connection from EKS
    kubectl run db-test --image=postgres:15-alpine --rm -it --restart=Never -n $NAMESPACE \
      --env="PGPASSWORD=${DB_PASSWORD}" \
      -- psql -h $RDS_ENDPOINT -U dbadmin -d devopsagentdb -c "SELECT 1 as connection_test;" || \
      echo "Connection failed (check Security Group or RDS status)"
    ;;

  23|rds-connection-flood)
    echo "=== Scenario I01: RDS Connection Limit Exceeded ==="
    echo "Creating multiple connections to exhaust connection pool..."
    echo "WARNING: This may affect database performance"
    
    RDS_ENDPOINT=$(aws rds describe-db-instances \
      --db-instance-identifier devops-agent-test-database \
      --query 'DBInstances[0].Endpoint.Address' \
      --output text \
      $AWS_OPTS)
    
    echo "RDS Endpoint: $RDS_ENDPOINT"
    echo "Spawning 50 concurrent connections..."
    
    for i in $(seq 1 50); do
      kubectl run db-conn-$i --image=postgres:15-alpine --restart=Never -n $NAMESPACE \
        --env="PGPASSWORD=${DB_PASSWORD}" \
        -- sh -c "psql -h $RDS_ENDPOINT -U dbadmin -d devopsagentdb -c 'SELECT pg_sleep(300);'" &
    done
    
    echo "Waiting for pods to start..."
    sleep 10
    
    echo ""
    echo "Connection pods status:"
    kubectl get pods -n $NAMESPACE | grep db-conn
    
    echo ""
    echo "To cleanup: kubectl delete pods -n $NAMESPACE -l run=db-conn --force"
    ;;

  24|rds-conn-cleanup)
    echo "=== Cleaning up RDS connection test pods ==="
    kubectl delete pods -n $NAMESPACE -l run --field-selector=status.phase!=Running --force 2>/dev/null || true
    for i in $(seq 1 50); do
      kubectl delete pod db-conn-$i -n $NAMESPACE --force 2>/dev/null &
    done
    wait
    echo "Cleanup completed."
    ;;

  25|iam-deny)
    echo "=== Scenario I03: IAM Permission Denied ==="
    echo "This scenario simulates IRSA permission issues"
    echo ""
    echo "Creating pod that tries to access Secrets Manager without permission..."
    
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-iam-denied
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-iam-denied
  template:
    metadata:
      labels:
        app: test-iam-denied
    spec:
      # No serviceAccountName - uses default without IRSA
      containers:
      - name: aws-cli
        image: amazon/aws-cli:latest
        command: ["sh", "-c", "while true; do echo 'Attempting to read secret...'; aws secretsmanager get-secret-value --secret-id devops-agent-test/database/credentials --region us-east-1 2>&1 || echo 'ERROR: Access Denied'; sleep 10; done"]
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
EOF
    
    sleep 10
    echo ""
    echo "Pod logs (should show AccessDeniedException):"
    kubectl logs -n $NAMESPACE -l app=test-iam-denied --tail=10
    ;;

  26|secrets-missing)
    echo "=== Scenario I04: Secrets Manager Access Failure ==="
    echo "Creating pod that references non-existent secret via External Secrets..."
    
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-secret-access-fail
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-secret-access-fail
  template:
    metadata:
      labels:
        app: test-secret-access-fail
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sh", "-c", "echo 'Waiting for secret mount...' && ls -la /secrets/ 2>&1 || echo 'ERROR: Secret not mounted' && sleep 3600"]
        volumeMounts:
        - name: db-secret
          mountPath: /secrets
          readOnly: true
      volumes:
      - name: db-secret
        secret:
          secretName: nonexistent-aws-secret
          optional: false
EOF
    
    sleep 5
    echo ""
    echo "Pod status (should show CreateContainerConfigError):"
    kubectl get pods -n $NAMESPACE -l app=test-secret-access-fail
    kubectl describe pod -n $NAMESPACE -l app=test-secret-access-fail | grep -A5 "Events:"
    ;;

  27|external-connectivity)
    echo "=== Scenario I05: External Connectivity Test ==="
    echo "Testing NAT Gateway / external connectivity..."
    
    kubectl run ext-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s --max-time 10 https://api.github.com/zen || echo "External connectivity failed"
    ;;

  # ============================================
  # Database Connection Scenarios
  # ============================================

  30|db-pool)
    echo "=== Scenario: Database Connection Pool (Proper) ==="
    kubectl run db-pool-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/db-pool
    ;;

  31|db-leak)
    echo "=== Scenario I01: Database Connection Leak ==="
    COUNT=${2:-10}
    echo "Creating $COUNT leaked connections..."
    kubectl run db-leak-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s "http://rng/db-leak?count=$COUNT"
    ;;

  32|db-flood)
    echo "=== Scenario I01: Database Connection Flood ==="
    MAX=${2:-50}
    echo "Attempting to open $MAX connections..."
    kubectl run db-flood-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s "http://rng/db-flood?max=$MAX"
    ;;

  33|db-leak-status)
    echo "=== Database Leak Status ==="
    kubectl run db-status --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/db-leak-status
    ;;

  34|db-leak-cleanup)
    echo "=== Cleaning up leaked connections ==="
    kubectl run db-cleanup --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/db-leak-cleanup
    ;;

  # ============================================
  # AWS FIS Experiments
  # ============================================

  40|fis-list)
    echo "=== FIS Experiment Templates ==="
    aws fis list-experiment-templates \
      --query 'experimentTemplates[?contains(tags.Environment, `devops-agent-test`)].[id,tags.Name,tags.Scenario]' \
      --output table \
      $AWS_OPTS
    ;;

  41|fis-node-terminate)
    echo "=== FIS: EKS Node Termination ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I07-node-failure`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  42|fis-rds-reboot)
    echo "=== FIS: RDS Reboot ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I08-rds-failover`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  43|fis-rds-failover)
    echo "=== FIS: RDS Multi-AZ Failover ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I09-rds-failover-forced`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  44|fis-network-disrupt)
    echo "=== FIS: Network Disruption ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I10-network-failure`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  45|fis-cpu-stress)
    echo "=== FIS: Node CPU Stress ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I11-node-cpu-stress`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  46|fis-memory-stress)
    echo "=== FIS: Node Memory Stress ==="
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I12-node-memory-stress`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    echo "Starting experiment: $TEMPLATE_ID"
    aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS
    ;;

  47|fis-status)
    echo "=== FIS Experiment Status ==="
    aws fis list-experiments \
      --query 'experiments[?state.status!=`completed`].[id,experimentTemplateId,state.status,creationTime]' \
      --output table \
      $AWS_OPTS
    ;;

  48|fis-stop)
    EXPERIMENT_ID=$2
    if [ -z "$EXPERIMENT_ID" ]; then
      echo "Usage: $0 fis-stop <experiment-id>"
      exit 1
    fi
    echo "Stopping experiment: $EXPERIMENT_ID"
    aws fis stop-experiment \
      --id $EXPERIMENT_ID \
      $AWS_OPTS
    ;;

  cleanup)
    echo "=== Cleaning up test deployments ==="
    kubectl delete deployment test-imagepull-fail -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-crashloop -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-quota-exceed -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-service-discovery -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-network-blocked -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-pvc-pending -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-hpa-target -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-configmap-missing -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-secret-missing -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-liveness-fail -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-readiness-fail -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-iam-denied -n $NAMESPACE --ignore-not-found
    kubectl delete deployment test-secret-access-fail -n $NAMESPACE --ignore-not-found
    kubectl delete service test-network-blocked -n $NAMESPACE --ignore-not-found
    kubectl delete service test-readiness-fail -n $NAMESPACE --ignore-not-found
    kubectl delete networkpolicy test-deny-all-ingress -n $NAMESPACE --ignore-not-found
    kubectl delete pvc test-pvc-fail -n $NAMESPACE --ignore-not-found
    kubectl delete hpa test-hpa-fail -n $NAMESPACE --ignore-not-found
    kubectl delete resourcequota test-restrictive-quota -n $NAMESPACE --ignore-not-found
    kubectl delete resourcequota test-quota -n $NAMESPACE --ignore-not-found
    # Cleanup RDS connection test pods
    for i in $(seq 1 50); do
      kubectl delete pod db-conn-$i -n $NAMESPACE --force 2>/dev/null &
    done
    wait 2>/dev/null
    echo "Cleanup completed."
    ;;

  status)
    echo "=== Current Test Scenario Status ==="
    echo ""
    echo "Test Deployments:"
    kubectl get deployments -n $NAMESPACE -l 'app in (test-imagepull-fail,test-crashloop,test-quota-exceed,test-service-discovery)'
    echo ""
    echo "Test Pods:"
    kubectl get pods -n $NAMESPACE | grep -E "^test-|NAME"
    echo ""
    echo "Resource Quotas:"
    kubectl get resourcequota -n $NAMESPACE
    ;;

  # ============================================
  # Composite Scenarios (복합 시나리오) - 인과관계 기반
  # ============================================
  # 설계 원칙:
  # 1. 인과관계 명확: A → B → C 형태의 연쇄 장애
  # 2. 현실성: 실제 운영에서 발생 가능한 패턴
  # 3. 검증 가능: 각 단계의 영향을 확인 가능

  50|composite-redis-cascade)
    echo "=== C01: Redis 장애 전파 (Cache/Queue Cascade) ==="
    echo ""
    echo "인과관계: redis 다운 → worker ConnectionError → 처리량 0"
    echo ""
    echo "Step 1: 현재 worker 상태 확인..."
    kubectl get pods -n $NAMESPACE -l app=worker
    echo ""
    echo "Step 2: Redis Pod 삭제 (근본 원인)..."
    kubectl delete pod -n $NAMESPACE -l app=redis --force --grace-period=0
    echo ""
    echo "Step 3: Worker 로그 모니터링 (연쇄 영향)..."
    echo "Waiting 10 seconds for cascade effect..."
    sleep 10
    echo ""
    echo "Worker logs (should show ConnectionError to redis:6379):"
    kubectl logs -n $NAMESPACE -l app=worker --tail=20
    echo ""
    echo "Step 4: Redis 복구 대기..."
    echo "Redis will auto-restart. Check with: kubectl get pods -n $NAMESPACE -l app=redis"
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: redis Pod 장애"
    echo "  - Impact: worker 서비스 중단"
    echo "  - NOT: worker 코드 버그"
    ;;

  51|composite-network-cascade)
    echo "=== C02: 네트워크 차단 연쇄 (SG → DB → App Cascade) ==="
    echo ""
    echo "인과관계: SG 규칙 제거 → DB 연결 타임아웃 → rng HTTP 에러"
    echo ""
    echo "Step 1: 현재 Security Group 상태 확인..."
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=devops-agent-test-db-sg" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      $AWS_OPTS)
    echo "RDS Security Group: $SG_ID"
    echo ""
    echo "Step 2: RDS 포트 차단 (근본 원인)..."
    aws ec2 revoke-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.11.0/24 \
      $AWS_OPTS 2>/dev/null || true
    aws ec2 revoke-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.12.0/24 \
      $AWS_OPTS 2>/dev/null || true
    echo "Security Group rules revoked."
    echo ""
    echo "Step 3: DB 연결 시도 (연쇄 영향)..."
    echo "This will timeout after ~30 seconds..."
    kubectl run c02-db-test --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
      -- curl -s http://rng/db-pool --max-time 35 || echo "Connection timed out (expected cascade effect)"
    echo ""
    echo "Step 4: Security Group 복원..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.11.0/24 \
      $AWS_OPTS 2>/dev/null || true
    aws ec2 authorize-security-group-ingress \
      --group-id $SG_ID \
      --protocol tcp --port 5432 \
      --cidr 10.0.12.0/24 \
      $AWS_OPTS 2>/dev/null || true
    echo "Security Group rules restored."
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: Security Group 변경"
    echo "  - Impact: DB 연결 실패 → 앱 에러"
    echo "  - NOT: DB 서버 장애, 앱 버그"
    ;;

  52|composite-node-cascade)
    echo "=== C03: 노드 장애 연쇄 (Node → Pod → Service Cascade) ==="
    echo ""
    echo "인과관계: 노드 종료 → Pod Terminating → 재스케줄링 → 일시적 서비스 중단"
    echo ""
    echo "Step 1: 현재 노드 및 Pod 분포 확인..."
    kubectl get nodes
    echo ""
    kubectl get pods -n $NAMESPACE -o wide
    echo ""
    echo "Step 2: FIS로 노드 종료 (근본 원인)..."
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I07-node-failure`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ] || [ "$TEMPLATE_ID" = "None" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    EXPERIMENT_ID=$(aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS \
      --query 'experiment.id' --output text)
    echo "FIS Experiment started: $EXPERIMENT_ID"
    echo ""
    echo "Step 3: Pod 상태 모니터링 (연쇄 영향)..."
    echo "Waiting 30 seconds for cascade effect..."
    sleep 30
    echo ""
    echo "Pod status (should show Terminating/Pending):"
    kubectl get pods -n $NAMESPACE -o wide
    echo ""
    echo "Events:"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -10
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: EKS 노드 장애"
    echo "  - Impact: Pod 재스케줄링, 일시적 서비스 중단"
    echo "  - NOT: Pod 자체 문제"
    ;;

  53|composite-rds-cascade)
    echo "=== C04: RDS 페일오버 연쇄 (DB Failover → Connection → App Cascade) ==="
    echo ""
    echo "인과관계: RDS 재시작 → 기존 연결 끊김 → 앱 에러 → 복구"
    echo ""
    echo "Step 1: 현재 RDS 상태 확인..."
    aws rds describe-db-instances \
      --db-instance-identifier devops-agent-test-database \
      --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]' \
      --output table \
      $AWS_OPTS
    echo ""
    echo "Step 2: FIS로 RDS 재시작 (근본 원인)..."
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I08-rds-failover`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ] || [ "$TEMPLATE_ID" = "None" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    EXPERIMENT_ID=$(aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS \
      --query 'experiment.id' --output text)
    echo "FIS Experiment started: $EXPERIMENT_ID"
    echo ""
    echo "Step 3: DB 연결 시도 (연쇄 영향)..."
    echo "Attempting connections during RDS reboot..."
    for i in {1..3}; do
      echo "Attempt $i:"
      kubectl run c04-db-$i --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
        -- curl -s http://rng/db-pool --max-time 15 2>/dev/null || echo "Connection failed (expected during reboot)"
      sleep 5
    done
    echo ""
    echo "Step 4: RDS 상태 모니터링..."
    aws rds describe-db-instances \
      --db-instance-identifier devops-agent-test-database \
      --query 'DBInstances[0].DBInstanceStatus' \
      --output text \
      $AWS_OPTS
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: RDS 재시작/페일오버"
    echo "  - Impact: DB 연결 에러, 앱 일시 중단"
    echo "  - NOT: 앱 코드 버그, 네트워크 문제"
    ;;

  54|composite-service-cascade)
    echo "=== C05: 서비스 의존성 장애 (Service Dependency Cascade) ==="
    echo ""
    echo "인과관계: hasher 다운 → worker 호출 실패 → 처리량 저하"
    echo ""
    echo "Step 1: 현재 서비스 상태 확인..."
    kubectl get pods -n $NAMESPACE -l 'app in (hasher,worker)'
    echo ""
    echo "Step 2: Hasher Pod 삭제 (근본 원인)..."
    kubectl delete pod -n $NAMESPACE -l app=hasher --force --grace-period=0
    echo ""
    echo "Step 3: Worker 로그 모니터링 (연쇄 영향)..."
    echo "Waiting 10 seconds for cascade effect..."
    sleep 10
    echo ""
    echo "Worker logs (should show ConnectionError to hasher):"
    kubectl logs -n $NAMESPACE -l app=worker --tail=20
    echo ""
    echo "Step 4: Hasher 복구 대기..."
    echo "Hasher will auto-restart. Check with: kubectl get pods -n $NAMESPACE -l app=hasher"
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: hasher 서비스 장애"
    echo "  - Impact: worker 처리 실패"
    echo "  - NOT: worker 코드 버그"
    ;;

  55|composite-resource-cascade)
    echo "=== C06: 리소스 경쟁 연쇄 (Resource Contention Cascade) ==="
    echo ""
    echo "인과관계: CPU 스트레스 → 앱 응답 지연 → 타임아웃 → 에러 증가"
    echo ""
    echo "Step 1: 현재 노드 리소스 확인..."
    kubectl top nodes 2>/dev/null || echo "Metrics server may not be available"
    echo ""
    echo "Step 2: FIS로 노드 CPU 스트레스 (근본 원인)..."
    TEMPLATE_ID=$(aws fis list-experiment-templates \
      --query 'experimentTemplates[?tags.Scenario==`I11-node-cpu-stress`].id' \
      --output text \
      $AWS_OPTS)
    
    if [ -z "$TEMPLATE_ID" ] || [ "$TEMPLATE_ID" = "None" ]; then
      echo "ERROR: FIS template not found. Deploy 07-fis-experiments.yml first."
      exit 1
    fi
    
    EXPERIMENT_ID=$(aws fis start-experiment \
      --experiment-template-id $TEMPLATE_ID \
      $AWS_OPTS \
      --query 'experiment.id' --output text)
    echo "FIS Experiment started: $EXPERIMENT_ID"
    echo ""
    echo "Step 3: 서비스 응답 시간 테스트 (연쇄 영향)..."
    echo "Waiting 20 seconds for CPU stress to take effect..."
    sleep 20
    echo ""
    echo "Testing hasher response time:"
    for i in {1..3}; do
      echo "Request $i:"
      time kubectl run c06-test-$i --image=curlimages/curl --rm -it --restart=Never -n $NAMESPACE \
        -- curl -s http://hasher/32 --max-time 10 2>/dev/null || echo "Timeout or slow response (expected)"
    done
    echo ""
    echo "Step 4: FIS 실험 상태 확인..."
    aws fis get-experiment \
      --id $EXPERIMENT_ID \
      --query 'experiment.state.status' \
      --output text \
      $AWS_OPTS
    echo ""
    echo "To stop experiment: ./trigger-scenarios.sh fis-stop $EXPERIMENT_ID"
    echo ""
    echo "Expected Agent Analysis:"
    echo "  - Root Cause: 노드 CPU 리소스 부족"
    echo "  - Impact: 앱 응답 지연, 타임아웃"
    echo "  - NOT: 앱 코드 성능 문제"
    ;;

  56|composite-cleanup)
    echo "=== Cleaning up composite scenario resources ==="
    # Stop any running FIS experiments
    echo "Checking for running FIS experiments..."
    RUNNING=$(aws fis list-experiments \
      --query 'experiments[?state.status==`running`].id' \
      --output text \
      $AWS_OPTS)
    for exp in $RUNNING; do
      echo "Stopping experiment: $exp"
      aws fis stop-experiment --id $exp \
        $AWS_OPTS 2>/dev/null || true
    done
    
    # Cleanup test pods
    echo "Cleaning up test pods..."
    kubectl delete pods -n $NAMESPACE -l run --force 2>/dev/null || true
    
    # Restore Security Group if needed
    echo "Ensuring Security Group rules are restored..."
    SG_ID=$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=devops-agent-test-db-sg" \
      --query 'SecurityGroups[0].GroupId' \
      --output text \
      $AWS_OPTS 2>/dev/null)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
      aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp --port 5432 \
        --cidr 10.0.11.0/24 \
        $AWS_OPTS 2>/dev/null || true
      aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp --port 5432 \
        --cidr 10.0.12.0/24 \
        $AWS_OPTS 2>/dev/null || true
    fi
    
    echo "Composite scenario cleanup completed."
    ;;

  # ============================================
  # Data Corruption Scenario (실제 서비스 체인 기반)
  # ============================================

  60|corrupted-data)
    echo "=== Scenario: Corrupted Data from RNG ==="
    echo ""
    echo "인과관계: rng 데이터 오염 → worker 전달 → hasher 검증 실패 → X-Ray fault trace"
    echo ""
    echo "Step 1: 현재 서비스 상태 확인..."
    kubectl get pods -n $NAMESPACE -l 'app in (rng,hasher,worker)'
    echo ""
    echo "Step 2: RNG 응답 품질 저하 모드 활성화 (50% 확률)..."
    kubectl exec -n $NAMESPACE deployment/rng -- python3 -c "import urllib.request; urllib.request.urlopen('http://localhost/config/response?quality=degraded&rate=0.5')"
    echo ""
    echo "RNG will now return corrupted (empty) data 10% of the time."
    echo "Worker will pass this to hasher, which will reject it with HTTP 400."
    echo ""
    echo "Step 3: 대기 중 (worker가 자동으로 호출)..."
    echo "Worker calls rng → hasher every ~0.1 seconds."
    echo "Waiting 30 seconds for fault traces to accumulate..."
    sleep 30
    echo ""
    echo "Step 4: Worker 로그 확인 (hasher 검증 실패 확인)..."
    kubectl logs -n $NAMESPACE -l app=worker --tail=30 | grep -i "error\|400\|validation" || echo "No errors in recent logs (may need more time)"
    echo ""
    echo "Step 5: X-Ray trace 확인..."
    echo "Check X-Ray Console for traces with:"
    echo "  - Service: hasher"
    echo "  - HTTP Status: 400"
    echo "  - Error Type: ValidationError"
    echo "  - Trace: worker → rng (OK) → worker → hasher (FAULT)"
    echo ""
    echo "Step 6: CloudWatch 메트릭 확인..."
    echo "Check CloudWatch Application Signals for:"
    echo "  - hasher Fault count increase"
    echo "  - hasher HTTP 4xx errors"
    echo ""
    echo "To restore normal operation:"
    echo "  kubectl exec -n $NAMESPACE deployment/rng -- python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost/config/response?quality=normal')\""
    echo ""
    echo "To change degradation rate:"
    echo "  kubectl exec -n $NAMESPACE deployment/rng -- python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost/config/response?quality=degraded&rate=0.5')\""
    ;;

  61|corrupted-data-restore)
    echo "=== Restoring Normal RNG Operation ==="
    kubectl exec -n $NAMESPACE deployment/rng -- python3 -c "import urllib.request; urllib.request.urlopen('http://localhost/config/response?quality=normal')"
    echo "RNG response quality restored to normal."
    ;;

  62|corrupted-data-status)
    echo "=== RNG Response Quality Status ==="
    kubectl exec -n $NAMESPACE deployment/rng -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost/health/detailed').read().decode())" 2>/dev/null || echo "Could not reach RNG health endpoint"
    echo ""
    echo "Recent worker logs:"
    kubectl logs -n $NAMESPACE -l app=worker --tail=20
    ;;

  *)
    echo "DevOps Agent Test Scenario Trigger"
    echo ""
    echo "Usage: $0 <scenario>"
    echo ""
    echo "=== Application Layer ==="
    echo "  1, oom              - OOMKilled (memory limit exceeded)"
    echo "  4, latency          - High Latency (slow responses)"
    echo "  7, error            - HTTP 500 Errors"
    echo "  8, cpu              - CPU Spike"
    echo "  9, dependency       - Dependency Failure"
    echo ""
    echo "=== Kubernetes Platform Layer ==="
    echo "  2, imagepull        - ImagePullBackOff (wrong image tag)"
    echo "  3, crashloop        - CrashLoopBackOff (app startup failure)"
    echo "  5, quota            - Resource Quota Exceeded"
    echo "  6, servicediscovery - Service Discovery Failure"
    echo "  10, networkpolicy   - NetworkPolicy Block"
    echo "  11, pvc             - PVC Binding Failure"
    echo "  12, hpa             - HPA Scaling Failure"
    echo "  13, configmap       - ConfigMap Missing"
    echo "  14, secret          - Secret Missing"
    echo "  15, liveness        - Liveness Probe Failure"
    echo "  16, readiness       - Readiness Probe Failure"
    echo ""
    echo "=== AWS Infrastructure Layer ==="
    echo "  20, sg-block        - Security Group Block (RDS)"
    echo "  21, sg-restore      - Restore Security Group Rules"
    echo "  22, rds-connection  - Test RDS Connection"
    echo "  25, iam-deny        - IAM Permission Denied"
    echo "  26, secrets-missing - Secrets Manager Access Failure"
    echo "  27, external-connectivity - NAT Gateway Test"
    echo ""
    echo "=== Database Connection Scenarios ==="
    echo "  30, db-pool         - Database Pool (proper)"
    echo "  31, db-leak [N]     - Connection Leak (N connections)"
    echo "  32, db-flood [N]    - Connection Flood (max N)"
    echo "  33, db-leak-status  - Check leaked connections"
    echo "  34, db-leak-cleanup - Cleanup leaked connections"
    echo ""
    echo "=== AWS FIS Experiments ==="
    echo "  40, fis-list        - List FIS experiment templates"
    echo "  41, fis-node-terminate - Terminate EKS node"
    echo "  42, fis-rds-reboot  - Reboot RDS instance"
    echo "  43, fis-rds-failover - Force RDS Multi-AZ failover"
    echo "  44, fis-network-disrupt - Network disruption"
    echo "  45, fis-cpu-stress  - Node CPU stress"
    echo "  46, fis-memory-stress - Node memory stress"
    echo "  47, fis-status      - Check running experiments"
    echo "  48, fis-stop <id>   - Stop experiment"
    echo ""
    echo "=== Composite Scenarios (복합 - 인과관계 기반) ==="
    echo "  50, composite-redis-cascade    - C01: Redis 장애 전파 (redis→worker→throughput)"
    echo "  51, composite-network-cascade  - C02: 네트워크 차단 연쇄 (SG→DB→app)"
    echo "  52, composite-node-cascade     - C03: 노드 장애 연쇄 (node→pod→service)"
    echo "  53, composite-rds-cascade      - C04: RDS 페일오버 연쇄 (RDS→connection→app)"
    echo "  54, composite-service-cascade  - C05: 서비스 의존성 장애 (hasher→worker)"
    echo "  55, composite-resource-cascade - C06: 리소스 경쟁 연쇄 (CPU→latency→timeout)"
    echo "  56, composite-cleanup          - 복합 시나리오 정리"
    echo ""
    echo "=== Data Corruption Scenario (실제 서비스 체인) ==="
    echo "  60, corrupted-data         - RNG 데이터 오염 (rng→worker→hasher fault trace)"
    echo "  61, corrupted-data-restore - RNG 정상 모드 복원"
    echo "  62, corrupted-data-status  - RNG 오염 상태 확인"
    echo ""
    echo "=== Management ==="
    echo "  cleanup             - Remove all test deployments"
    echo "  status              - Show current test scenario status"
    ;;
esac
