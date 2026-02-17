#!/bin/bash

set -e

echo "🚀 Installing Jenkins in Kubernetes"
echo "===================================="
echo ""

# -----------------------------------------------------------------------------
# Configuration - Load from .env file
# -----------------------------------------------------------------------------

# Determine directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env file - check in order: custom location, project root, home directory
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
elif [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
elif [ -f "$HOME/.env" ]; then
    source "$HOME/.env"
fi

# Jenkins Configuration (with defaults)
JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-jenkins}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-changeme}"

# GitHub Configuration
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Docker Hub Configuration
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-admin@example.com}"

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  JENKINS_NAMESPACE: $JENKINS_NAMESPACE"
    echo "  DOCKERHUB_USERNAME: $DOCKERHUB_USERNAME"
    echo "  GITHUB_USERNAME: $GITHUB_USERNAME"
    echo ""
fi

# ========================================
# 🎨 Colors for output
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_red() { echo -e "${RED}$1${NC}"; }
print_green() { echo -e "${GREEN}$1${NC}"; }
print_blue() { echo -e "${BLUE}$1${NC}"; }
print_yellow() { echo -e "${YELLOW}$1${NC}"; }

# -----------------------------------------------------------------------------
# 🧭 Define directories
# -----------------------------------------------------------------------------
JENKINS_DIR="$PROJECT_ROOT/jenkins-k8s/base"

# Check if manifests directory exists
if [ ! -d "$JENKINS_DIR" ]; then
    print_red "❌ Jenkins manifests not found at: $JENKINS_DIR"
    echo ""
    echo "Expected structure:"
    echo "  $PROJECT_ROOT/"
    echo "  └── jenkins-k8s/"
    echo "      └── base/"
    echo "          ├── 00-namespace.yaml"
    echo "          ├── 01-serviceaccount.yaml"
    echo "          ├── 02-clusterrole.yaml"
    echo "          ├── 03-clusterrolebinding.yaml"
    echo "          ├── 04-pvc.yaml"
    echo "          ├── 05-configmap.yaml"
    echo "          ├── 06-deployment.yaml"
    echo "          ├── 07-rbac.yaml"
    echo "          └── 08-service.yaml"
    echo ""
    echo "Please create the jenkins-k8s directory structure first."
    exit 1
fi

print_blue "Using manifests from: $JENKINS_DIR"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Build Jenkins Docker Image with Docker CLI (AUTOMATED!)
# -----------------------------------------------------------------------------
echo "=========================================="
print_blue "Step -1: Preparing Jenkins with Docker CLI"
echo "=========================================="
echo ""

# Check if image exists on Docker Hub (not just locally)
if ! docker pull rinavillaruz/jenkins-docker:latest > /dev/null 2>&1; then
    echo "Image not found on Docker Hub. Building..."
    docker rmi rinavillaruz/jenkins-docker:latest 2>/dev/null || true
    
    # Create Dockerfile if it doesn't exist
    if [ ! -f "$PROJECT_ROOT/jenkins-k8s/docker/Dockerfile" ]; then
        echo "Creating Dockerfile..."
        mkdir -p "$PROJECT_ROOT/jenkins-k8s/docker"
        cat > "$PROJECT_ROOT/jenkins-k8s/docker/Dockerfile" <<'EOF'
FROM jenkins/jenkins:lts-jdk21

USER root

# Install Docker CLI (latest version), kubectl, Helm, Buildx, and jq
RUN apt-get update && \
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        jq && \
    # =================================================================
    # Docker Installation
    # =================================================================
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    # Install Docker CLI and Buildx
    apt-get update && \
    apt-get install -y \
        docker-ce-cli \
        docker-buildx-plugin && \
    # =================================================================
    # kubectl Installation
    # =================================================================
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl && \
    # =================================================================
    # Helm Installation
    # =================================================================
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
    # =================================================================
    # User Setup
    # =================================================================
    # Add jenkins to docker group
    groupadd -f docker && \
    usermod -aG docker jenkins && \
    # =================================================================
    # Cleanup
    # =================================================================
    rm -rf /var/lib/apt/lists/*

# Verify all installations
RUN echo "========================================" && \
    echo "✅ Installed versions:" && \
    docker --version && \
    kubectl version --client && \
    helm version && \
    jq --version && \
    echo "========================================"

USER jenkins
EOF
        print_green "✅ Dockerfile created"
    fi
    
    echo ""
    echo "🐳 Building Jenkins image with Docker, kubectl, and Helm..."
    cd "$PROJECT_ROOT/jenkins-k8s/docker"
    docker build -t rinavillaruz/jenkins-docker:latest . || {
        print_red "❌ Docker build failed"
        exit 1
    }
    print_green "✅ Jenkins image built successfully"
    
    echo ""
    # Automated Docker login
    if [ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ]; then
        echo "🔑 Logging into Docker Hub..."
        echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin 2>/dev/null || {
            print_red "❌ Docker login failed"
            exit 1
        }
        print_green "✅ Logged into Docker Hub"
    else
        print_yellow "⚠️  Docker Hub credentials not found in .env"
        read -p "Login manually now? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            docker login || exit 1
        else
            print_yellow "⚠️  Image not pushed to Docker Hub"
            echo "You can push later with: docker push rinavillaruz/jenkins-docker:latest"
            cd "$PROJECT_ROOT"
        fi
    fi
    
    # Push if logged in
    if docker info 2>&1 | grep -q "Username:"; then
        echo ""
        echo "📤 Pushing image to Docker Hub..."
        docker push rinavillaruz/jenkins-docker:latest || {
            print_red "❌ Push failed"
        }
        print_green "✅ Image pushed to Docker Hub"
    fi
    
    print_green "✅ Image ready"
    cd "$PROJECT_ROOT"
    echo ""
else
    print_green "✅ Jenkins Docker image already exists on Docker Hub"
    echo "To rebuild: docker rmi rinavillaruz/jenkins-docker:latest"
    echo ""
fi

echo ""

# -----------------------------------------------------------------------------
# Step 2: Create secrets
# -----------------------------------------------------------------------------
echo "=========================================="
print_blue "Step 0: Load Configuration & Create Secrets"
echo "=========================================="
echo ""

# Create Jenkins namespace first
echo "Creating Jenkins namespace..."
kubectl create namespace "$JENKINS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
print_green "✅ Namespace created/verified"

# Create Jenkins admin credentials secret from .env or use default
echo "Creating Jenkins admin credentials..."
kubectl create secret generic jenkins-admin-credentials \
    --from-literal=password="$JENKINS_ADMIN_PASSWORD" \
    -n "$JENKINS_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
print_green "✅ Jenkins credentials created"

# Create GitHub credentials secret
if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_TOKEN" ]; then
    kubectl create secret generic github-credentials \
        --from-literal=username="$GITHUB_USERNAME" \
        --from-literal=token="$GITHUB_TOKEN" \
        -n "$JENKINS_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_green "✅ GitHub credentials secret created"
else
    print_yellow "⚠️  GitHub credentials not found in .env"
fi

# Create Docker Hub credentials secret
if [ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ]; then
    kubectl create secret generic dockerhub-credentials \
        --from-literal=username="$DOCKERHUB_USERNAME" \
        --from-literal=token="$DOCKERHUB_TOKEN" \
        -n "$JENKINS_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_green "✅ Docker Hub credentials secret created"
else
    print_yellow "⚠️  Docker Hub credentials not found in .env"
fi

# Create ImagePullSecret for private Docker Hub repository
if [ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ]; then
    echo "Creating ImagePullSecret for private Docker Hub repository..."
    kubectl create secret docker-registry dockerhub-pull-secret \
        --docker-server=https://index.docker.io/v1/ \
        --docker-username="$DOCKERHUB_USERNAME" \
        --docker-password="$DOCKERHUB_TOKEN" \
        --docker-email="$DOCKERHUB_EMAIL" \
        -n "$JENKINS_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    print_green "✅ ImagePullSecret created for private repository"
else
    print_yellow "⚠️  Cannot create ImagePullSecret - Docker Hub credentials missing"
fi

echo ""

# -----------------------------------------------------------------------------
# Step 3: Create ServiceAccount
# -----------------------------------------------------------------------------
print_blue "Step 1: Creating ServiceAccount..."
kubectl apply -f "$JENKINS_DIR/01-serviceaccount.yaml"
print_green "✅ ServiceAccount created"
echo ""

# -----------------------------------------------------------------------------
# Step 4: Set up RBAC (Jenkins namespace access)
# -----------------------------------------------------------------------------
print_blue "Step 2: Setting up RBAC (ClusterRole & Binding)..."
kubectl apply -f "$JENKINS_DIR/02-clusterrole.yaml"
kubectl apply -f "$JENKINS_DIR/03-clusterrolebinding.yaml"
print_green "✅ RBAC configured"
echo ""

# -----------------------------------------------------------------------------
# Step 5: Create PersistentVolumeClaim
# -----------------------------------------------------------------------------
print_blue "Step 3: Creating PersistentVolumeClaim..."
kubectl apply -f "$JENKINS_DIR/04-pvc.yaml"

# Wait for PVC to be bound
echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/jenkins-pvc -n "$JENKINS_NAMESPACE" --timeout=60s || {
    print_yellow "⚠️  PVC not bound yet, continuing anyway..."
}
print_green "✅ PVC created"
echo ""

# -----------------------------------------------------------------------------
# Step 6: Create Jenkins Init Scripts ConfigMap
# -----------------------------------------------------------------------------
print_blue "Step 4: Creating Jenkins init scripts..."
if [ -f "$JENKINS_DIR/08-init-configmap.yaml" ]; then
    kubectl apply -f "$JENKINS_DIR/08-init-configmap.yaml"
    print_green "✅ Init scripts ConfigMap created"
    echo ""
else
    print_yellow "⚠️  08-init-configmap.yaml not found, skipping"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 7: Create ConfigMap (JCasC & plugins.txt)
# -----------------------------------------------------------------------------
print_blue "Step 5: Creating Jenkins Configuration..."
kubectl apply -f "$JENKINS_DIR/05-configmap.yaml"
print_green "✅ ConfigMap created"
echo ""

# -----------------------------------------------------------------------------
# Step 8: Deploy Jenkins
# -----------------------------------------------------------------------------
print_blue "Step 6: Deploying Jenkins..."
kubectl apply -f "$JENKINS_DIR/06-deployment.yaml"
print_green "✅ Deployment created"
echo ""

# -----------------------------------------------------------------------------
# Step 9: Set up Jenkins RBAC for Deployments
# -----------------------------------------------------------------------------
print_blue "Step 7: Setting up Jenkins deployment permissions..."
if [ -f "$JENKINS_DIR/07-rbac.yaml" ]; then
    kubectl apply -f "$JENKINS_DIR/07-rbac.yaml"
    print_green "✅ Deployment RBAC configured"
    print_green "   Jenkins can now deploy to Kubernetes!"
    echo ""
else
    print_yellow "⚠️  07-rbac.yaml not found"
    print_yellow "⚠️  Jenkins may not have permissions to deploy applications"
    print_yellow "   Create 07-rbac.yaml to grant deployment permissions"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 10: Create Service
# -----------------------------------------------------------------------------
print_blue "Step 8: Creating Jenkins Service..."
if [ -f "$JENKINS_DIR/08-service.yaml" ]; then
    kubectl apply -f "$JENKINS_DIR/08-service.yaml"
    print_green "✅ Service created"
    echo ""
elif [ -f "$JENKINS_DIR/07-service.yaml" ]; then
    # Fallback for old naming
    print_yellow "⚠️  Using old filename: 07-service.yaml"
    print_yellow "   Consider renaming to 08-service.yaml"
    kubectl apply -f "$JENKINS_DIR/07-service.yaml"
    print_green "✅ Service created"
    echo ""
else
    print_red "❌ Service file not found"
    print_red "   Expected: $JENKINS_DIR/08-service.yaml"
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 11: Wait for Jenkins to be ready
# -----------------------------------------------------------------------------
print_blue "Step 9: Waiting for Jenkins pod to be ready..."
echo "This may take 2-3 minutes (downloading image and installing plugins)..."
echo ""

# Show init container logs while waiting
echo "Watching plugin installation..."
sleep 5

JENKINS_POD=""
for i in {1..30}; do
    JENKINS_POD=$(kubectl get pods -n "$JENKINS_NAMESPACE" -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$JENKINS_POD" ]; then
        break
    fi
    echo "Waiting for pod to be created... ($i/30)"
    sleep 2
done

if [ -n "$JENKINS_POD" ]; then
    echo "Pod found: $JENKINS_POD"
    echo "Checking init container status..."
    
    # Check if init container is running
    INIT_STATUS=$(kubectl get pod -n "$JENKINS_NAMESPACE" $JENKINS_POD -o jsonpath='{.status.initContainerStatuses[0].state}' 2>/dev/null || echo "")
    
    if echo "$INIT_STATUS" | grep -q "running"; then
        echo "Init container is installing plugins..."
        echo "You can watch logs with: kubectl logs -n $JENKINS_NAMESPACE $JENKINS_POD -c install-plugins -f"
    fi
fi

kubectl wait --for=condition=ready pod -l app=jenkins -n "$JENKINS_NAMESPACE" --timeout=300s || {
    print_red "❌ Jenkins pod did not become ready in time"
    echo ""
    echo "Check pod status:"
    echo "  kubectl get pods -n $JENKINS_NAMESPACE"
    echo ""
    echo "Check init container logs:"
    echo "  kubectl logs -n $JENKINS_NAMESPACE $JENKINS_POD -c install-plugins"
    echo ""
    echo "Check main container logs:"
    echo "  kubectl logs -n $JENKINS_NAMESPACE $JENKINS_POD -c jenkins"
    echo ""
    echo "Check events:"
    echo "  kubectl get events -n $JENKINS_NAMESPACE --sort-by='.lastTimestamp'"
    exit 1
}

print_green "✅ Jenkins is ready!"
echo ""

# -----------------------------------------------------------------------------
# Step 12: Get Jenkins info and verify plugins
# -----------------------------------------------------------------------------
JENKINS_POD=$(kubectl get pods -n "$JENKINS_NAMESPACE" -l app=jenkins -o jsonpath='{.items[0].metadata.name}')

print_blue "Step 10: Retrieving Jenkins information..."
echo "Jenkins Pod: $JENKINS_POD"
echo ""

# Check plugin installation
echo "Verifying plugin installation..."
PLUGIN_COUNT=$(kubectl exec -n "$JENKINS_NAMESPACE" $JENKINS_POD -- find /var/jenkins_home/plugins -name "*.jpi" -o -name "*.hpi" 2>/dev/null | wc -l || echo "0")

if [ "$PLUGIN_COUNT" -gt 20 ]; then
    print_green "✅ $PLUGIN_COUNT plugins installed successfully"
else
    print_yellow "⚠️  Only $PLUGIN_COUNT plugins found"
    echo "Check init container logs for errors:"
    echo "  kubectl logs -n $JENKINS_NAMESPACE $JENKINS_POD -c install-plugins"
fi

echo ""

# Verify kubectl, helm, and docker are installed
echo "Verifying tools in Jenkins container..."
kubectl exec -n "$JENKINS_NAMESPACE" $JENKINS_POD -- docker --version
kubectl exec -n "$JENKINS_NAMESPACE" $JENKINS_POD -- kubectl version --client
kubectl exec -n "$JENKINS_NAMESPACE" $JENKINS_POD -- helm version

echo ""

# -----------------------------------------------------------------------------
# Display access information
# -----------------------------------------------------------------------------
echo "=========================================="
print_green "✅ Jenkins Installation Complete!"
echo "=========================================="
echo ""
print_blue "Access Information:"
echo "  URL: http://localhost:30808"
echo "  Username: admin"
echo "  Password: $JENKINS_ADMIN_PASSWORD"
echo ""
print_yellow "⚠️  IMPORTANT: Change the admin password after first login!"
echo ""
echo "=========================================="
print_blue "Resources Created:"
echo "=========================================="
echo ""

# Show all resources
kubectl get all,pvc,configmap,secret -n "$JENKINS_NAMESPACE"

echo ""
echo "=========================================="
print_blue "RBAC Permissions:"
echo "=========================================="
echo ""
kubectl get clusterrole jenkins-deployer 2>/dev/null && echo "  ✅ ClusterRole: jenkins-deployer" || echo "  ❌ ClusterRole: Not found"
kubectl get clusterrolebinding jenkins-deployer-binding 2>/dev/null && echo "  ✅ ClusterRoleBinding: jenkins-deployer-binding" || echo "  ❌ ClusterRoleBinding: Not found"

echo ""
echo "=========================================="
print_yellow "📝 Next Steps"
echo "=========================================="
echo ""
echo "1. Open Jenkins UI:"
echo "   http://localhost:30808"
echo ""
echo "2. Login with credentials shown above"
echo ""
echo "3. Verify plugins are installed:"
echo "   Manage Jenkins → Plugins → Installed plugins"
echo ""
echo "4. Create your first pipeline:"
echo "   New Item → Pipeline → OK"
echo "   - Pipeline definition: Pipeline script from SCM"
echo "   - SCM: Git"
echo "   - Repository URL: https://github.com/rinavillaruz/jeffrey-epstein-files.git"
echo "   - Script Path: ci/Jenkinsfile"
echo ""
echo "=========================================="
print_blue "ℹ️  Useful Commands"
echo "=========================================="
echo ""
echo "View Jenkins logs:"
echo "  kubectl logs -n $JENKINS_NAMESPACE $JENKINS_POD -c jenkins -f"
echo ""
echo "Test kubectl access:"
echo "  kubectl exec -n $JENKINS_NAMESPACE $JENKINS_POD -- kubectl get namespaces"
echo ""
echo "Test helm:"
echo "  kubectl exec -n $JENKINS_NAMESPACE $JENKINS_POD -- helm list -A"
echo ""
echo "Test docker:"
echo "  kubectl exec -n $JENKINS_NAMESPACE $JENKINS_POD -- docker ps"
echo ""
echo "Restart Jenkins:"
echo "  kubectl rollout restart deployment/jenkins -n $JENKINS_NAMESPACE"
echo ""
echo "Uninstall Jenkins:"
echo "  kubectl delete namespace $JENKINS_NAMESPACE"
echo "  kubectl delete clusterrole jenkins-deployer"
echo "  kubectl delete clusterrolebinding jenkins-deployer-binding"
echo ""