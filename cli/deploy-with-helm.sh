#!/bin/bash

set -e  # Exit on any error

echo ""
echo "🚀 Deploying Jeffrey Epstein Files Platform with Helm..."
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

# MongoDB Configuration (needed for secrets)
MONGODB_USERNAME="${MONGODB_USERNAME:-admin}"
MONGODB_PASSWORD="${MONGODB_PASSWORD:-}"

# Cluster Configuration
CLUSTER_NAME="${CLUSTER_NAME:-jeffrey-epstein-files-dev}"

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  MONGODB_USERNAME: $MONGODB_USERNAME"
    echo "  CLUSTER_NAME: $CLUSTER_NAME"
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

# ========================================
# 📥 Parse arguments
# ========================================
ENVIRONMENT=${1:-dev}
IMAGE_TAG=${2:-latest}

print_blue "🎯 Deploying to environment: $ENVIRONMENT"
echo ""
print_blue "📦 Image tag: $IMAGE_TAG"
echo ""

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
    print_red "❌ Invalid environment: $ENVIRONMENT"
    echo "Valid options: dev, staging, production"
    exit 1
fi

# ========================================
# 🔧 Determine namespace from environment
# ========================================
case "$ENVIRONMENT" in
    dev)
        NAMESPACE="data-dev"
        ;;
    staging)
        NAMESPACE="data-staging"
        ;;
    production)
        NAMESPACE="data-production"
        ;;
esac

print_blue "📦 Target namespace: $NAMESPACE"
echo ""

# ========================================
# 🔐 Step 1: Detect environment and load credentials
# ========================================
print_blue "🔐 Step 0: Loading environment variables..."

if [ -n "$JENKINS_HOME" ]; then
    print_blue "🤖 Running in Jenkins CI/CD"
    IN_JENKINS=true
    SKIP_KIND=true
    SKIP_METRICS=true
    export DEBIAN_FRONTEND=noninteractive
    
    # Set kubeconfig if running in Jenkins
    export KUBECONFIG=${KUBECONFIG:-/var/jenkins_home/.kube/config}
    
    # Try to set context to kind-kind
    if kubectl config get-contexts kind-kind &> /dev/null; then
        kubectl config use-context kind-kind
        print_green "✅ Using kind-kind context"
    else
        print_yellow "⚠️  kind-kind context not found, using current context"
    fi
    
    # Verify kubectl can connect
    if ! kubectl cluster-info &> /dev/null; then
        print_red "❌ Cannot connect to Kubernetes cluster"
        print_yellow "Attempting to list available contexts..."
        kubectl config get-contexts || true
        exit 1
    fi
    
    print_green "✅ Kubernetes connection verified"
    
    # Load credentials from environment
    export MONGODB_USERNAME=${MONGODB_USERNAME:-admin}
    export MONGODB_PASSWORD=${MONGODB_PASSWORD:-password123}
    
else
    print_blue "💻 Running locally"
    IN_JENKINS=false
    SKIP_KIND=false
    SKIP_METRICS=false
    
    # Check if .env exists
    if [ ! -f "$PROJECT_ROOT/.env" ]; then
        print_red "❌ Error: .env file not found in project root!"
        echo "Please create a .env file with:"
        echo "  MONGODB_USERNAME=your_username"
        echo "  MONGODB_PASSWORD=your_password"
        exit 1
    fi
fi

# Verify required variables
if [ -z "$MONGODB_USERNAME" ] || [ -z "$MONGODB_PASSWORD" ]; then
    print_red "❌ Error: MONGODB_USERNAME or MONGODB_PASSWORD not set"
    echo ""
    echo "Make sure your .env file contains:"
    echo "  MONGODB_USERNAME=admin"
    echo "  MONGODB_PASSWORD=your_secure_password"
    exit 1
fi

print_green "✅ Environment variables loaded"
echo ""

# ========================================
# 🔍 Step 2: Cluster setup
# ========================================
if [ "$SKIP_KIND" = false ]; then
    print_blue "🔍 Step 1: Checking for existing cluster..."
    if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        print_yellow "⚠️  Cluster '$CLUSTER_NAME' already exists. Skipping creation."
    else
        print_blue "🏗️  Creating directories..."
        mkdir -p "$PROJECT_ROOT/data"/{control-plane-{1..3},ml-training,mongodb,redis} "$PROJECT_ROOT/models"
        
        print_blue "🏗️  Creating Kind cluster..."
        kind create cluster --config "$PROJECT_ROOT/k8s/kind-cluster.yaml" --name "$CLUSTER_NAME"
        print_green "✅ Cluster created"
        
        echo "⏳ Waiting for cluster to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=180s
        print_green "✅ Cluster is ready"
    fi
else
    print_blue "🔍 Step 1: Using existing Kubernetes cluster"
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
    echo "Current context: $CURRENT_CONTEXT"
    
    # Show available contexts if connection fails
    if [ "$CURRENT_CONTEXT" = "none" ]; then
        print_yellow "Available contexts:"
        kubectl config get-contexts || print_red "No kubeconfig found"
    fi
    
    print_green "✅ Cluster ready"
fi
echo ""

# ========================================
# 📊 Step 3: Metrics Server
# ========================================
if [ "$SKIP_METRICS" = false ]; then
    print_blue "📊 Step 1.5: Installing Metrics Server..."
    
    if ! kubectl cluster-info &> /dev/null; then
        print_red "❌ Cannot connect to cluster"
        echo "Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
        exit 1
    fi

    if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
        print_yellow "⚠️  Metrics server already installed"
    else
        echo "Installing metrics server..."
        kubectl apply --validate=false -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        
        sleep 5
        
        echo "Patching metrics server for Kind cluster..."
        kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
        {
            "op": "add",
            "path": "/spec/template/spec/containers/0/args/-",
            "value": "--kubelet-insecure-tls"
        }
        ]'
        
        print_green "✅ Metrics server installed"
        echo "⏳ Waiting for metrics server to be ready..."
        kubectl wait --for=condition=available --timeout=120s deployment/metrics-server -n kube-system || {
            print_yellow "⚠️  Metrics server still starting (this is OK)"
        }
    fi
else
    print_blue "📊 Step 1.5: Skipping metrics server (already installed)"
fi
echo ""

# ========================================
# 🌐 Step 4: Ingress Controller
# ========================================
if [ "$SKIP_METRICS" = false ]; then
    print_blue "🌐 Step 1.6: Checking Ingress Controller..."
    
    if kubectl get namespace ingress-nginx &> /dev/null; then
        print_green "✅ Ingress Controller already installed"
    else
        print_blue "Installing nginx Ingress Controller..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
        
        echo "⏳ Waiting for Ingress Controller to be ready..."
        kubectl wait --namespace ingress-nginx \
          --for=condition=ready pod \
          --selector=app.kubernetes.io/component=controller \
          --timeout=120s || {
            print_yellow "⚠️  Ingress Controller still starting (this is OK)"
        }
        print_green "✅ Ingress Controller installed"
    fi
else
    print_blue "🌐 Step 1.6: Skipping Ingress Controller (already installed)"
fi
echo ""

# ========================================
# 📦 Step 5: Create namespaces
# ========================================
print_blue "📦 Step 2: Creating namespaces..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ml-pipeline --dry-run=client -o yaml | kubectl apply -f -
print_green "✅ Namespaces created"
echo ""

sleep 2

# ========================================
# 🔐 Step 6: Create secrets
# ========================================
print_blue "🔐 Step 3: Creating secrets in $NAMESPACE..."
kubectl create secret generic mongodb-secret \
  --from-literal=username="$MONGODB_USERNAME" \
  --from-literal=password="$MONGODB_PASSWORD" \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret mongodb-secret -n $NAMESPACE &> /dev/null; then
    print_green "✅ MongoDB secret created successfully in $NAMESPACE"
else
    print_red "❌ Failed to create MongoDB secret"
    exit 1
fi
echo ""

# ========================================
# 🐳 Step 7: Build and Load Docker Images (Local only)
# ========================================
if [ "$IN_JENKINS" = false ]; then
    print_blue "🐳 Step 3.5: Building and loading Docker images into Kind..."
    cd "$PROJECT_ROOT"
    
    # Build API image
    if [ -f "build/Dockerfile.dev" ]; then
        print_blue "Building API image..."
        docker build -t jeffrey-epstein-files-api:${IMAGE_TAG} -f build/Dockerfile.dev . || {
            print_red "❌ Failed to build API image"
            exit 1
        }
        print_green "✅ API image built"
        
        # Load into Kind cluster
        print_blue "Loading API image into Kind..."
        kind load docker-image jeffrey-epstein-files-api:${IMAGE_TAG} --name "$CLUSTER_NAME" || {
            print_red "❌ Failed to load API image into Kind"
            exit 1
        }
        print_green "✅ API image loaded into cluster"
    else
        print_yellow "⚠️  build/Dockerfile.dev not found, skipping API build"
    fi
    echo ""
    
    # Build Jupyter image (only for dev environment)
    if [ "$ENVIRONMENT" = "dev" ]; then
        if [ -f "build/Dockerfile.jupyter" ]; then
            print_blue "Building Jupyter image..."
            docker build -t jeffrey-epstein-files-jupyter:${IMAGE_TAG} -f build/Dockerfile.jupyter . || {
                print_red "❌ Failed to build Jupyter image"
                exit 1
            }
            print_green "✅ Jupyter image built"
            
            # Load into Kind cluster
            print_blue "Loading Jupyter image into Kind..."
            kind load docker-image jeffrey-epstein-files-jupyter:${IMAGE_TAG} --name "$CLUSTER_NAME" || {
                print_red "❌ Failed to load Jupyter image into Kind"
                exit 1
            }
            print_green "✅ Jupyter image loaded into cluster"
        else
            print_yellow "⚠️  build/Dockerfile.jupyter not found, skipping Jupyter build"
        fi
        echo ""
    fi
    
    print_green "✅ All images built and loaded into Kind cluster"
else
    print_blue "🐳 Step 3.5: Skipping image build (running in Jenkins)"
    print_yellow "Images should be pulled from Docker Hub in CI/CD pipeline"
fi
echo ""

# ========================================
# 🔧 Step 8: Fix PVC Ownership
# ========================================
print_blue "🔧 Step 3.6: Ensuring PVC ownership for Helm..."

RELEASE_NAME="jeffrey-epstein-files"

# Get all PVCs in the namespace
PVCS=$(kubectl get pvc -n $NAMESPACE -o name 2>/dev/null || echo "")

if [ -n "$PVCS" ]; then
    print_yellow "Found existing PVCs - adding Helm ownership labels..."
    
    for pvc in $PVCS; do
        PVC_NAME=$(echo $pvc | cut -d'/' -f2)
        
        # Check if PVC already has Helm label
        CURRENT_OWNER=$(kubectl get pvc $PVC_NAME -n $NAMESPACE -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
        
        if [ "$CURRENT_OWNER" != "Helm" ]; then
            print_yellow "  Fixing ownership for: $PVC_NAME"
            
            # Add Helm ownership label
            kubectl label pvc $PVC_NAME -n $NAMESPACE \
                app.kubernetes.io/managed-by=Helm \
                --overwrite &>/dev/null || true
            
            # Add Helm release annotations
            kubectl annotate pvc $PVC_NAME -n $NAMESPACE \
                meta.helm.sh/release-name=$RELEASE_NAME \
                meta.helm.sh/release-namespace=$NAMESPACE \
                --overwrite &>/dev/null || true
            
            print_green "    ✓ Added Helm ownership to $PVC_NAME"
        else
            print_green "    ✓ $PVC_NAME already managed by Helm"
        fi
    done
    
    print_green "✅ All PVCs have Helm ownership"
else
    print_blue "  No existing PVCs found - Helm will create them"
fi

echo ""

# ========================================
# 🎡 Step 9: Deploy with Helm
# ========================================
print_blue "🎡 Step 4: Deploying with Helm..."

# Navigate to helm chart directory
HELM_DIR="$PROJECT_ROOT/deploy/helm"
if [ ! -d "$HELM_DIR" ]; then
    print_red "❌ Cannot find Helm chart directory: $HELM_DIR"
    exit 1
fi

cd "$HELM_DIR"
print_blue "Current directory: $(pwd)"

# Validate Helm chart
echo "Validating Helm chart..."
if helm lint .; then
    print_green "✅ Helm chart validation passed"
else
    print_red "❌ Helm chart validation failed"
    exit 1
fi
echo ""

# Check if values file exists
if [ ! -f "values-${ENVIRONMENT}.yaml" ]; then
    print_red "❌ Error: values-${ENVIRONMENT}.yaml not found!"
    echo ""
    echo "Available values files:"
    ls -1 values*.yaml 2>/dev/null || echo "No values files found"
    echo ""
    print_yellow "💡 Make sure you have created values-${ENVIRONMENT}.yaml"
    exit 1
fi

print_blue "Using values file: values-${ENVIRONMENT}.yaml"
echo ""

# Install or upgrade using single release name
echo "Installing/upgrading Helm release..."
if helm upgrade --install jeffrey-epstein-files . \
  --namespace $NAMESPACE \
  --create-namespace \
  --values values-${ENVIRONMENT}.yaml \
  --set global.imageTag=${IMAGE_TAG} \
  --set mongodb.auth.username="$MONGODB_USERNAME" \
  --set mongodb.auth.password="$MONGODB_PASSWORD" \
  --timeout 10m \
  --wait; then
    print_green "✅ Helm deployment successful"
else
    print_red "❌ Helm deployment failed"
    echo ""
    print_yellow "Troubleshooting tips:"
    echo "  1. Check if values-${ENVIRONMENT}.yaml is valid"
    echo "  2. Run: helm lint . -f values-${ENVIRONMENT}.yaml"
    echo "  3. Check logs: kubectl logs -n $NAMESPACE -l app=jeffrey-epstein-files-api"
    echo "  4. Check pod status: kubectl get pods -n $NAMESPACE"
    echo "  5. Describe pod: kubectl describe pod -n $NAMESPACE <pod-name>"
    exit 1
fi

echo ""

# ========================================
# ⏳ Step 10: Wait for pods
# ========================================
print_blue "⏳ Step 5: Waiting for pods to be ready..."
print_yellow "This may take a few minutes..."
echo ""

# Wait for any pods to appear first
echo "Waiting for pods to be created..."
sleep 10

# Check what pods exist
echo "Current pods in $NAMESPACE namespace:"
kubectl get pods -n $NAMESPACE 2>/dev/null || print_yellow "No pods found yet"
echo ""

# Try to wait for common pods
echo "Waiting for MongoDB..."
if kubectl wait --for=condition=ready pod -l app=mongodb -n $NAMESPACE --timeout=180s 2>/dev/null; then
    print_green "✅ MongoDB ready"
else
    print_yellow "⚠️  MongoDB pods not found or not ready yet"
    kubectl get pods -n $NAMESPACE -l app=mongodb 2>/dev/null || echo "No MongoDB pods"
fi
echo ""

echo "Waiting for Redis..."
if kubectl wait --for=condition=ready pod -l app=redis -n $NAMESPACE --timeout=120s 2>/dev/null; then
    print_green "✅ Redis ready"
else
    print_yellow "⚠️  Redis pods not found or not ready yet"
    kubectl get pods -n $NAMESPACE -l app=redis 2>/dev/null || echo "No Redis pods"
fi
echo ""

# Check for API pods
echo "Checking for API pods..."
if kubectl get pods -n $NAMESPACE -l app=jeffrey-epstein-files-api &>/dev/null; then
    echo "Waiting for API..."
    if kubectl wait --for=condition=ready pod -l app=jeffrey-epstein-files-api -n $NAMESPACE --timeout=120s 2>/dev/null; then
        print_green "✅ API ready"
    else
        print_yellow "⚠️  API not ready yet"
    fi
else
    print_yellow "⚠️  No API pods found"
fi
echo ""

# Check for Jupyter pods (only in dev)
if [ "$ENVIRONMENT" = "dev" ]; then
    echo "Checking for Jupyter pods..."
    if kubectl get pods -n $NAMESPACE -l app=jupyter &>/dev/null; then
        echo "Waiting for Jupyter..."
        if kubectl wait --for=condition=ready pod -l app=jupyter -n $NAMESPACE --timeout=120s 2>/dev/null; then
            print_green "✅ Jupyter ready"
        else
            print_yellow "⚠️  Jupyter not ready yet"
        fi
    else
        print_yellow "⚠️  No Jupyter pods found (expected for dev)"
    fi
    echo ""
fi

print_green "✅ Pod readiness check complete"
echo ""

# ========================================
# 📊 Step 11: Show deployment status
# ========================================
print_blue "📊 Deployment Status:"
echo ""
echo "=========================================="
echo "Helm Releases:"
echo "=========================================="
helm list -A
echo ""
echo "=========================================="
echo "Pods in $NAMESPACE namespace:"
echo "=========================================="
kubectl get pods -n $NAMESPACE -o wide 2>/dev/null || echo "No pods in $NAMESPACE namespace"
echo ""
echo "=========================================="
echo "Services in $NAMESPACE namespace:"
echo "=========================================="
kubectl get svc -n $NAMESPACE 2>/dev/null || echo "No services in $NAMESPACE namespace"
echo ""

# Show PVCs
echo "=========================================="
echo "PersistentVolumeClaims in $NAMESPACE namespace:"
echo "=========================================="
kubectl get pvc -n $NAMESPACE 2>/dev/null || echo "No PVCs in $NAMESPACE namespace"
echo ""

# ========================================
# 🎉 Success
# ========================================
echo ""
print_green "=========================================="
print_green "🎉 Deployment Complete!"
print_green "=========================================="
echo ""
echo "Environment: $ENVIRONMENT"
echo "Image Tag: $IMAGE_TAG"
echo "Namespace: $NAMESPACE"
echo ""

# Show service URLs if available
if [ "$ENVIRONMENT" = "dev" ]; then
    echo "=========================================="
    echo "🌐 Service URLs:"
    echo "=========================================="
    
    # Check if Ingress exists
    if kubectl get ingress -n $NAMESPACE &>/dev/null; then
        print_green "Via Ingress (Recommended):"
        echo "  API:     http://localhost/api/health"
        echo "  Jupyter: http://localhost/jupyter"
        echo ""
    fi
    
    # Also show NodePort as backup
    print_yellow "Via NodePort (Backup):"
    API_NODEPORT=$(kubectl get svc jeffrey-epstein-files-api-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$API_NODEPORT" ]; then
        echo "  API: http://localhost:$API_NODEPORT"
    fi
    
    JUPYTER_NODEPORT=$(kubectl get svc jupyter -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$JUPYTER_NODEPORT" ]; then
        echo "  Jupyter: http://localhost:$JUPYTER_NODEPORT"
    fi
    echo ""
fi

echo "=========================================="
echo "📝 Useful Commands:"
echo "=========================================="
echo ""
echo "Check pod status:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "View logs:"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/instance=jeffrey-epstein-files --tail=50"
echo "  kubectl logs -f -n $NAMESPACE deployment/jeffrey-epstein-files-api"
echo ""
echo "Describe failing pods:"
echo "  kubectl describe pods -n $NAMESPACE"
echo ""
echo "Check Helm release:"
echo "  helm list -n $NAMESPACE"
echo "  helm status jeffrey-epstein-files -n $NAMESPACE"
echo "  helm history jeffrey-epstein-files -n $NAMESPACE"
echo ""
echo "Access services via Ingress:"
echo "  curl http://localhost/api/health"
if [ "$ENVIRONMENT" = "dev" ]; then
    echo "  open http://localhost/jupyter"
fi
echo ""
echo "Port forward services (if Ingress not working):"
echo "  kubectl port-forward -n $NAMESPACE svc/jeffrey-epstein-files-api-service 8000:8000"
if [ "$ENVIRONMENT" = "dev" ]; then
    echo "  kubectl port-forward -n $NAMESPACE svc/jupyter 8888:8888"
fi
echo ""
echo "Run ML training:"
echo "  ./run-training.sh"
echo ""
echo "Upgrade deployment:"
echo "  helm upgrade jeffrey-epstein-files ./deploy/helm -f values-${ENVIRONMENT}.yaml --set global.imageTag=NEW_TAG -n $NAMESPACE"
echo ""
echo "Rollback deployment:"
echo "  helm rollback jeffrey-epstein-files -n $NAMESPACE"
echo ""
echo "Uninstall:"
echo "  helm uninstall jeffrey-epstein-files -n $NAMESPACE"
echo ""
echo "Debug pod issues:"
echo "  kubectl exec -it -n $NAMESPACE <pod-name> -- bash"
echo "  kubectl logs -n $NAMESPACE <pod-name> --previous  # View logs from crashed pod"
echo ""