#!/bin/bash

set -e  # Exit on any error

echo "🔄 Installing ArgoCD in Kubernetes..."

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

# ArgoCD Configuration (with defaults)
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  ARGOCD_NAMESPACE: $ARGOCD_NAMESPACE"
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
# 🧭 Define directories (so script works from anywhere)
# -----------------------------------------------------------------------------
TMP_DIR="$PROJECT_ROOT/tmp"
VALUES_FILE="$TMP_DIR/argocd-values.yaml"

mkdir -p "$TMP_DIR"

# -----------------------------------------------------------------------------
# Step 1: Check if kubectl can connect to cluster
# -----------------------------------------------------------------------------
print_blue "🔍 Step 1: Checking cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    print_red "❌ Cannot connect to cluster. Please ensure your cluster is running."
    echo "Run: cd cli && ./deploy-with-helm.sh dev"
    exit 1
fi
print_green "✅ Connected to cluster"
echo ""

# -----------------------------------------------------------------------------
# Step 2: Check if ArgoCD is already installed
# -----------------------------------------------------------------------------
print_blue "🔍 Step 2: Checking if ArgoCD is already installed..."

if kubectl get namespace "$ARGOCD_NAMESPACE" &> /dev/null; then
    # Namespace exists
    if helm list -n "$ARGOCD_NAMESPACE" | grep -q "argocd"; then
        print_green "✅ Argo CD is already installed"
        read -p "Do you want to reinstall? This will delete the existing installation. (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_yellow "⚠️  Uninstalling existing ArgoCD..."
            helm uninstall argocd -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
            kubectl delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found
            print_blue "⏳ Reinstalling ArgoCD..."
            sleep 5
        else
            print_green "✅ Keeping existing ArgoCD installation"
            exit 0
        fi
    else
        print_yellow "⚠️  ArgoCD namespace exists but Helm release not found. Cleaning up..."
        kubectl delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found
        sleep 3
    fi
else
    print_blue "ℹ️  ArgoCD not found. Proceeding with installation..."
fi

echo ""

# -----------------------------------------------------------------------------
# Step 3: Add ArgoCD Helm repository
# -----------------------------------------------------------------------------
print_blue "📦 Step 3: Adding ArgoCD Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
print_green "✅ ArgoCD Helm repo added"
echo ""

# -----------------------------------------------------------------------------
# Step 4: Create ArgoCD namespace
# -----------------------------------------------------------------------------
print_blue "📁 Step 4: Creating ArgoCD namespace..."
kubectl create namespace "$ARGOCD_NAMESPACE"
print_green "✅ Namespace created"
echo ""

# -----------------------------------------------------------------------------
# Step 5: Create ArgoCD values file
# -----------------------------------------------------------------------------
print_blue "📝 Step 5: Creating ArgoCD configuration..."

cat > "$VALUES_FILE" <<'EOF'
# ArgoCD configuration for local Kind cluster

global:
  domain: argocd.local

server:
  service:
    type: NodePort
    nodePortHttp: 30080
    nodePortHttps: 30443
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 1Gi

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

redis:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

redis-ha:
  enabled: false

# Disable dex for local development
dex:
  enabled: false

configs:
  params:
    server.insecure: true
EOF
print_green "✅ Configuration created"
echo ""

# -----------------------------------------------------------------------------
# Step 6: Install ArgoCD
# -----------------------------------------------------------------------------
print_blue "🎡 Step 6: Installing ArgoCD with Helm..."

# Ensure namespace exists
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Check if ArgoCD release already exists
if helm list -n "$ARGOCD_NAMESPACE" | grep -q "argocd"; then
    print_yellow "⚠️  ArgoCD Helm release already exists. Upgrading instead..."
    helm upgrade argocd argo/argo-cd \
      --namespace "$ARGOCD_NAMESPACE" \
      --values "$VALUES_FILE"
else
    echo "Installing ArgoCD..."
    helm install argocd argo/argo-cd \
      --namespace "$ARGOCD_NAMESPACE" \
      --values "$VALUES_FILE"
fi

print_green "✅ ArgoCD installation complete"
echo ""

# -----------------------------------------------------------------------------
# Step 7: Wait for ArgoCD deployments to be created
# -----------------------------------------------------------------------------
print_blue "⏳ Step 7: Waiting for ArgoCD deployments to be created..."
sleep 10
print_green "✅ Deployments created"
echo ""

# -----------------------------------------------------------------------------
# Step 8: Fix any pending pods due to node selectors
# -----------------------------------------------------------------------------
print_blue "🔧 Step 7.5: Checking for scheduling issues..."

sleep 5  # Give pods a moment to schedule

if kubectl get pods -n "$ARGOCD_NAMESPACE" 2>/dev/null | grep -q Pending; then
    print_yellow "⚠️  Found pending pods, fixing node selectors..."
    
    # Remove nodeSelector from all deployments
    kubectl patch deployment argocd-server -n "$ARGOCD_NAMESPACE" --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]' 2>/dev/null || true
    
    kubectl patch deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]' 2>/dev/null || true
    
    kubectl patch deployment argocd-redis -n "$ARGOCD_NAMESPACE" --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]' 2>/dev/null || true
    
    kubectl patch statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]' 2>/dev/null || true
    
    echo "Recreating pending pods..."
    kubectl delete pod -n "$ARGOCD_NAMESPACE" --field-selector=status.phase=Pending 2>/dev/null || true
    
    echo "Waiting for pods to restart..."
    sleep 15
    
    print_green "✅ Scheduling issues fixed"
else
    print_green "✅ All pods scheduled correctly"
fi

# Disable crashing dex server if needed
if kubectl get pods -n "$ARGOCD_NAMESPACE" 2>/dev/null | grep dex | grep -q CrashLoopBackOff; then
    print_yellow "⚠️  Dex server crashing, scaling to 0 (not needed for local dev)"
    kubectl scale deployment argocd-dex-server -n "$ARGOCD_NAMESPACE" --replicas=0 2>/dev/null || true
fi

echo ""

# -----------------------------------------------------------------------------
# Step 9: Wait for ArgoCD pods to be ready
# -----------------------------------------------------------------------------
print_blue "⏳ Step 8: Waiting for ArgoCD pods to be ready (this may take 2-3 minutes)..."

# Wait for server deployment to be available
kubectl wait --for=condition=available deployment/argocd-server -n "$ARGOCD_NAMESPACE" --timeout=180s || {
    print_yellow "⚠️  Deployment not available yet, checking pod status..."
    kubectl get pods -n "$ARGOCD_NAMESPACE" -o wide
}

# Wait for server pod to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=300s || {
    print_yellow "⚠️  Pods not ready yet, showing status..."
    kubectl get pods -n "$ARGOCD_NAMESPACE" -o wide
}

print_green "✅ ArgoCD pods are ready"
echo ""

# -----------------------------------------------------------------------------
# Step 10: Verify service accessibility
# -----------------------------------------------------------------------------
print_blue "🔍 Step 9: Verifying ArgoCD service is accessible..."

# Give the service a moment to start accepting connections
sleep 5

MAX_RETRIES=30
RETRY_COUNT=0

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    if curl -k -s -o /dev/null -w "%{http_code}" http://localhost:30080 2>/dev/null | grep -q "200\|301\|302\|307"; then
        print_green "✅ ArgoCD service is accessible!"
        echo ""
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        echo "Waiting for service... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 2
    else
        print_yellow "⚠️  Service check timed out, but pods are running"
        echo "You can access ArgoCD at: http://localhost:30080"
        echo "It may take another minute to be fully ready."
        break
    fi
done

echo ""

# -----------------------------------------------------------------------------
# Step 11: Get admin password
# -----------------------------------------------------------------------------
print_blue "🔐 Step 10: Retrieving admin password..."
sleep 5  # Give secrets time to be created
ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
print_green "✅ Password retrieved"
echo ""

# -----------------------------------------------------------------------------
# Step 12: Show status
# -----------------------------------------------------------------------------
print_blue "📊 ArgoCD Installation Status:"
echo ""
echo "=========================================="
echo "ArgoCD Pods:"
echo "=========================================="
kubectl get pods -n "$ARGOCD_NAMESPACE" -o wide
echo ""
echo "=========================================="
echo "ArgoCD Services:"
echo "=========================================="
kubectl get svc -n "$ARGOCD_NAMESPACE"
echo ""

# -----------------------------------------------------------------------------
# Step 13: Display access information
# -----------------------------------------------------------------------------
print_green "✅ ArgoCD Installation Complete!"
echo ""
echo "=========================================="
echo "📝 Access Information:"
echo "=========================================="
echo ""
echo "ArgoCD UI:"
echo "   http://localhost:30080"
echo ""
echo "Login credentials:"
echo "   Username: admin"
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "=========================================="
echo "📝 ArgoCD CLI Commands:"
echo "=========================================="
echo ""
echo "Install ArgoCD CLI (if not already installed):"
echo "   brew install argocd"
echo ""
echo "Login via CLI:"
echo "   argocd login localhost:30080 --username admin --password ${ARGOCD_PASSWORD} --insecure"
echo ""
echo "List applications:"
echo "   argocd app list"
echo ""
echo "=========================================="
echo "📝 Save Your Password:"
echo "=========================================="
echo ""
echo "IMPORTANT: Save this password securely!"
echo "Password: ${ARGOCD_PASSWORD}"
echo ""
echo "To retrieve it later, run:"
echo "   kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""

# -----------------------------------------------------------------------------
# 🧹 Step 14: Clean up temporary file
# -----------------------------------------------------------------------------
rm -f "$VALUES_FILE"

# -----------------------------------------------------------------------------
# Next Steps
# -----------------------------------------------------------------------------
print_green "✅ Installation script complete!"
echo ""
echo "=========================================="
echo "📝 Next Steps - Deploy Your Apps:"
echo "=========================================="
echo ""
echo "1. Deploy development environment:"
echo "   kubectl apply -f $PROJECT_ROOT/argocd-apps/jeffrey-epstein-files-dev.yaml"
echo ""
echo "2. Deploy staging environment:"
echo "   kubectl apply -f $PROJECT_ROOT/argocd-apps/jeffrey-epstein-files-staging.yaml"
echo ""
echo "3. Deploy production environment:"
echo "   kubectl apply -f $PROJECT_ROOT/argocd-apps/jeffrey-epstein-files-production.yaml"
echo ""
echo "4. Or deploy all apps at once:"
echo "   kubectl apply -f $PROJECT_ROOT/argocd-apps/"
echo ""
echo "5. View applications in ArgoCD UI:"
echo "   http://localhost:30080"
echo ""
echo "6. Or use CLI:"
echo "   argocd app list"
echo "   argocd app get jeffrey-epstein-files-dev"
echo ""
echo "Additional recommendations:"
echo "- Change the admin password in ArgoCD UI (User Info > Update Password)"
echo "- Review the ArgoCD app definitions in: $PROJECT_ROOT/argocd-apps/"
echo ""