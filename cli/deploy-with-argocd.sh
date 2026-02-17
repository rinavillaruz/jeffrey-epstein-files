#!/bin/bash

set -e

echo "🚀 Deploying Jeffrey Epstein Files via ArgoCD"
echo "======================================="
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

# ArgoCD Configuration (with defaults)
ARGOCD_HOST="${ARGOCD_HOST:-localhost}"
ARGOCD_PORT="${ARGOCD_PORT:-30080}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_URL="http://${ARGOCD_HOST}:${ARGOCD_PORT}"

# GitHub Configuration (needed for repository verification)
GITHUB_USERNAME="${GITHUB_USERNAME:-rinavillaruz}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Parse environment argument
ENVIRONMENT=${1:-dev}

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  ARGOCD_URL: $ARGOCD_URL"
    echo "  ARGOCD_NAMESPACE: $ARGOCD_NAMESPACE"
    echo "  GITHUB_USERNAME: $GITHUB_USERNAME"
    echo "  ENVIRONMENT: $ENVIRONMENT"
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

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
    print_red "❌ Invalid environment: $ENVIRONMENT"
    echo "Usage: $0 [dev|staging|production]"
    echo ""
    echo "Examples:"
    echo "  $0 dev         # Deploy to development"
    echo "  $0 staging     # Deploy to staging"
    echo "  $0 production  # Deploy to production"
    exit 1
fi

# ========================================
# 🔧 Determine namespace and app name from environment
# ========================================
case "$ENVIRONMENT" in
    dev)
        NAMESPACE="data-dev"
        APP_NAME="jeffrey-epstein-files-dev"
        ;;
    staging)
        NAMESPACE="data-staging"
        APP_NAME="jeffrey-epstein-files-staging"
        ;;
    production)
        NAMESPACE="data-production"
        APP_NAME="jeffrey-epstein-files-prod"
        ;;
esac

print_blue "🎯 Deploying to environment: $ENVIRONMENT"
print_blue "📦 Target namespace: $NAMESPACE"
print_blue "📋 Application name: $APP_NAME"
echo ""

# -----------------------------------------------------------------------------
# 🧭 Define directories
# -----------------------------------------------------------------------------
ARGOCD_DIR="$PROJECT_ROOT/argocd-apps"
ARGOCD_APP_FILE="$ARGOCD_DIR/${APP_NAME}.yaml"

# -----------------------------------------------------------------------------
# Step 0: Validate Prerequisites
# -----------------------------------------------------------------------------
print_blue "Step 0: Validating prerequisites..."

if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_red "❌ ArgoCD namespace '$ARGOCD_NAMESPACE' not found"
    exit 1
fi

if ! kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
    print_red "❌ ArgoCD server is not running"
    exit 1
fi

print_green "✅ ArgoCD is running"

if [ ! -f "$ARGOCD_APP_FILE" ]; then
    print_red "❌ ${APP_NAME}.yaml not found at: $ARGOCD_APP_FILE"
    echo ""
    echo "Expected ArgoCD application files:"
    echo "  - argocd-apps/jeffrey-epstein-files-dev.yaml        (for dev)"
    echo "  - argocd-apps/jeffrey-epstein-files-staging.yaml    (for staging)"
    echo "  - argocd-apps/jeffrey-epstein-files-production.yaml (for production)"
    echo ""
    exit 1
fi

print_green "✅ Prerequisites validated"
echo ""

# -----------------------------------------------------------------------------
# Step 0.5: Verify ArgoCD Application CRD
# -----------------------------------------------------------------------------
print_blue "Step 0.5: Verifying ArgoCD CRDs..."

if ! kubectl get crd applications.argoproj.io &>/dev/null; then
    print_red "❌ ArgoCD Application CRD not found"
    echo "ArgoCD may not be properly installed"
    echo ""
    echo "Try reinstalling ArgoCD:"
    echo "  kubectl delete namespace $ARGOCD_NAMESPACE"
    echo "  ./cli/install-argocd.sh"
    exit 1
fi

print_green "✅ ArgoCD CRDs present"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Get Admin Credentials
# -----------------------------------------------------------------------------
print_blue "Step 1: Retrieving admin credentials..."

ADMIN_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

if [ -z "$ADMIN_PASSWORD" ]; then
    print_red "❌ Could not retrieve admin password"
    exit 1
fi

print_green "✅ Credentials retrieved"
echo "Username: admin"
echo "Password: $ADMIN_PASSWORD"
echo ""

# -----------------------------------------------------------------------------
# Step 2: Check ArgoCD Service Type
# -----------------------------------------------------------------------------
print_blue "Step 2: Checking ArgoCD service configuration..."

SERVICE_TYPE=$(kubectl get svc argocd-server -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.type}')

if [ "$SERVICE_TYPE" = "NodePort" ]; then
    NODEPORT=$(kubectl get svc argocd-server -n "$ARGOCD_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    ARGOCD_SERVER="${ARGOCD_HOST}:$NODEPORT"
    print_green "✅ ArgoCD accessible via NodePort: $NODEPORT"
    echo "Using: https://$ARGOCD_SERVER"
else
    print_yellow "⚠️  ArgoCD not configured as NodePort, setting up port-forward..."
    
    # Kill any existing port-forwards
    pkill -f "port-forward.*argocd-server" 2>/dev/null || true
    sleep 2
    
    # Start port-forward in background
    echo "Starting port-forward on localhost:8080..."
    kubectl port-forward -n "$ARGOCD_NAMESPACE" svc/argocd-server 8080:443 >/dev/null 2>&1 &
    PF_PID=$!
    
    # Wait for port-forward to establish
    sleep 5
    
    # Check if port-forward is working
    if ! lsof -Pi :8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
        print_red "❌ Port-forward failed to start"
        kill $PF_PID 2>/dev/null || true
        exit 1
    fi
    
    ARGOCD_SERVER="localhost:8080"
    print_green "✅ Port-forward established (PID: $PF_PID)"
fi

echo ""

# -----------------------------------------------------------------------------
# Step 3: Login to ArgoCD CLI
# -----------------------------------------------------------------------------
print_blue "Step 3: Logging into ArgoCD CLI..."

# Check if already logged in to the correct server
CURRENT_SERVER=$(argocd context 2>/dev/null | grep "^\*" | awk '{print $3}')

if [ "$CURRENT_SERVER" = "$ARGOCD_SERVER" ]; then
    print_green "✅ Already logged into $ARGOCD_SERVER"
else
    echo "Logging into $ARGOCD_SERVER..."
    
    # Use expect or printf to handle the TLS warning automatically
    if command -v expect &> /dev/null; then
        # Use expect if available
        expect << EOF
set timeout 15
spawn argocd login $ARGOCD_SERVER --username admin --password "$ADMIN_PASSWORD" --insecure
expect {
    "Proceed (y/n)?" { send "y\r"; exp_continue }
    "'admin:login' logged in successfully" { }
    timeout { exit 1 }
}
EOF
        LOGIN_EXIT=$?
    else
        # Fallback: use printf with pipe
        echo "y" | timeout 15 argocd login $ARGOCD_SERVER --username admin --password "$ADMIN_PASSWORD" --insecure 2>&1
        LOGIN_EXIT=$?
    fi
    
    if [ $LOGIN_EXIT -eq 0 ]; then
        print_green "✅ Successfully logged in"
    else
        print_red "❌ Login failed"
        echo ""
        echo "Try manual login:"
        echo "  argocd login $ARGOCD_SERVER --username admin --password '$ADMIN_PASSWORD' --insecure"
        [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
        exit 1
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Step 3.5: Verify Helm Chart in Repository
# -----------------------------------------------------------------------------
print_blue "Step 3.5: Verifying Helm chart exists in GitHub..."

REPO_OWNER="${GITHUB_USERNAME}"
REPO_NAME="jeffrey-epstein-files"
HELM_PATH="deploy/helm"

echo "Checking: https://github.com/$REPO_OWNER/$REPO_NAME/tree/main/$HELM_PATH"

# Build auth header if token is available
if [ -n "$GITHUB_TOKEN" ]; then
    AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
else
    AUTH_HEADER=""
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
  "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$HELM_PATH")

if [ "$HTTP_CODE" != "200" ]; then
    print_red "❌ Helm chart path not found in GitHub repository"
    echo ""
    echo "The path '$HELM_PATH' does not exist in your repository."
    echo ""
    echo "Please ensure you have:"
    echo "  1. Created the deploy/helm directory"
    echo "  2. Added Chart.yaml and values files"
    echo "  3. Committed and pushed to GitHub"
    echo ""
    echo "Quick fix:"
    echo "  mkdir -p deploy/helm/templates"
    echo "  # Add your Helm chart files"
    echo "  git add deploy/helm/"
    echo "  git commit -m 'Add Helm chart'"
    echo "  git push origin main"
    echo ""
    [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
    exit 1
fi

print_green "✅ Helm chart path exists in repository"

# Check for required files based on environment
VALUES_FILE="values-${ENVIRONMENT}.yaml"
for file in "Chart.yaml" "values.yaml" "$VALUES_FILE"; do
    FILE_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
      "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/$HELM_PATH/$file")
    
    if [ "$FILE_HTTP_CODE" = "200" ]; then
        print_green "  ✓ $file found"
    else
        print_yellow "  ⚠ $file not found"
        if [ "$file" = "$VALUES_FILE" ]; then
            print_red "    ERROR: $VALUES_FILE is required for $ENVIRONMENT environment"
            [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
            exit 1
        fi
    fi
done

echo ""

# -----------------------------------------------------------------------------
# Step 4: Apply ArgoCD Application Manifest
# -----------------------------------------------------------------------------
print_blue "Step 4: Applying ArgoCD Application manifest..."

# First, check if application already exists
if kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_yellow "⚠️  Application '$APP_NAME' already exists"
    
    # Show current status
    echo "Current application status:"
    kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "No status conditions"
    echo ""
    
    read -p "Delete and recreate? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Deleting existing application..."
        kubectl delete application $APP_NAME -n "$ARGOCD_NAMESPACE"
        echo "Waiting for deletion..."
        sleep 5
    else
        echo "Using existing application"
    fi
fi

# Apply the manifest
if kubectl apply -f "$ARGOCD_APP_FILE"; then
    print_green "✅ Application manifest applied"
else
    print_red "❌ Failed to apply manifest"
    echo ""
    echo "Debug: Checking manifest syntax..."
    kubectl apply -f "$ARGOCD_APP_FILE" --dry-run=client -o yaml
    [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "Waiting for ArgoCD to process application..."
sleep 5

# -----------------------------------------------------------------------------
# Step 5: Check Application Status
# -----------------------------------------------------------------------------
print_blue "Step 5: Checking application status..."

# First check if the Application CRD resource exists in Kubernetes
echo "Checking if Application resource exists in Kubernetes..."
if ! kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_red "❌ Application resource not found in Kubernetes"
    [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
    exit 1
fi

print_green "✅ Application resource exists in Kubernetes"

# Check for errors in the application status
APP_ERROR=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ComparisonError")].message}' 2>/dev/null)
if [ -n "$APP_ERROR" ]; then
    echo ""
    print_red "❌ Application has a ComparisonError:"
    echo "$APP_ERROR"
    [ ! -z "$PF_PID" ] && kill $PF_PID 2>/dev/null || true
    exit 1
fi

# Wait a bit for ArgoCD to fully process the application
echo "Waiting for ArgoCD to initialize application..."
sleep 10

# Try to access the app via CLI with --grpc-web flag (more reliable)
echo ""
echo "Checking if ArgoCD CLI can access the application..."

# Just try once with timeout
if timeout 10 argocd app get $APP_NAME --grpc-web &>/dev/null; then
    print_green "✅ Application accessible via ArgoCD CLI"
else
    print_yellow "⚠️  ArgoCD CLI access slow or failing, but proceeding anyway"
    echo "Application exists in Kubernetes and ArgoCD is processing it"
fi

echo ""
echo "Application details:"
argocd app get $APP_NAME --grpc-web 2>/dev/null || kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o yaml

echo ""

# Get application status from Kubernetes directly (more reliable)
APP_HEALTH=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
APP_SYNC=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

print_blue "Application Status:"
echo "  Health: $APP_HEALTH"
echo "  Sync:   $APP_SYNC"
echo ""

# -----------------------------------------------------------------------------
# Step 6: Verify Sync Status
# -----------------------------------------------------------------------------
print_blue "Step 6: Verifying sync status..."

# Check if sync already completed (automated sync)
SYNC_STATUS=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null)
OPERATION_PHASE=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null)

echo "Sync Status: $SYNC_STATUS"
echo "Operation Phase: $OPERATION_PHASE"

if [ "$SYNC_STATUS" = "Synced" ] && [ "$OPERATION_PHASE" = "Succeeded" ]; then
    print_green "✅ Application synced successfully (automated sync)"
elif [ "$SYNC_STATUS" = "Synced" ]; then
    print_green "✅ Application is synced"
elif [ "$SYNC_STATUS" = "OutOfSync" ]; then
    print_yellow "⚠️  Application is out of sync, triggering manual sync..."
    
    # Try to sync via CLI
    if argocd app sync $APP_NAME --grpc-web --server $ARGOCD_SERVER 2>/dev/null; then
        print_green "✅ Sync initiated via CLI"
    else
        # Fallback: use kubectl to trigger sync
        echo "CLI sync failed, using kubectl annotation to trigger sync..."
        kubectl annotate application $APP_NAME -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite
        print_green "✅ Sync triggered via annotation"
    fi
    
    # Wait for sync to complete
    echo "Waiting for sync to complete..."
    for i in {1..30}; do
        SYNC_STATUS=$(kubectl get application $APP_NAME -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null)
        if [ "$SYNC_STATUS" = "Synced" ]; then
            print_green "✅ Sync completed"
            break
        fi
        echo "Waiting... ($i/30)"
        sleep 2
    done
else
    print_yellow "⚠️  Unexpected sync status: $SYNC_STATUS"
fi

echo ""

# -----------------------------------------------------------------------------
# Step 7: Verify Deployment
# -----------------------------------------------------------------------------
echo "=========================================="
print_blue "Step 7: Verifying deployment..."
echo "=========================================="
echo ""

print_blue "ArgoCD Application Status:"
argocd app get $APP_NAME --refresh

echo ""
print_blue "Kubernetes Resources in '$NAMESPACE' namespace:"
kubectl get all -n $NAMESPACE 2>/dev/null || print_yellow "No resources in '$NAMESPACE' namespace yet"

echo ""
echo "=========================================="
print_green "✅ Deployment Complete!"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# Display Access Information
# -----------------------------------------------------------------------------
echo "=========================================="
print_yellow "📋 Access Information"
echo "=========================================="
echo ""
print_blue "Environment: $ENVIRONMENT"
print_blue "Namespace: $NAMESPACE"
print_blue "Application: $APP_NAME"
echo ""
print_blue "ArgoCD Web UI:"
echo "  https://$ARGOCD_SERVER"
echo ""
print_blue "Credentials:"
echo "  Username: admin"
echo "  Password: $ADMIN_PASSWORD"
echo ""
if [ ! -z "$PF_PID" ]; then
    print_blue "Port-forward PID: $PF_PID"
    echo "  To stop: kill $PF_PID"
    echo ""
fi

# -----------------------------------------------------------------------------
# Display Useful Commands
# -----------------------------------------------------------------------------
echo "=========================================="
print_yellow "📝 Useful Commands"
echo "=========================================="
echo ""
print_blue "ArgoCD CLI:"
echo "  argocd app list"
echo "  argocd app get $APP_NAME"
echo "  argocd app sync $APP_NAME"
echo "  argocd app logs $APP_NAME"
echo ""
print_blue "Kubernetes:"
echo "  kubectl get all -n $NAMESPACE"
echo "  kubectl logs -n $NAMESPACE <pod-name>"
echo "  kubectl get events -n $NAMESPACE"
echo ""
if [ ! -z "$PF_PID" ]; then
    print_blue "Port-forward:"
    echo "  To stop: kill $PF_PID"
    echo "  To restart: kubectl port-forward -n $ARGOCD_NAMESPACE svc/argocd-server 8080:443 &"
    echo ""
fi

echo "=========================================="
print_green "🎉 Happy Deploying!"
echo "=========================================="
echo ""

# Offer to keep port-forward running
if [ ! -z "$PF_PID" ]; then
    print_yellow "Note: Port-forward is running in background (PID: $PF_PID)"
    echo "Press Enter to stop it, or Ctrl+C to keep it running and exit"
    read -t 5 || true
    
    # If user pressed Enter, stop port-forward
    kill $PF_PID 2>/dev/null || true
    echo "Port-forward stopped."
fi