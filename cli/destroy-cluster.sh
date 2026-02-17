#!/bin/bash

set -e

echo "🧹 Cleaning up Jeffrey Epstein Files deployment..."

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

# Configuration (with defaults)
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-jenkins}"

# Auto-detect cluster name - use what Kind knows about
if [ -z "$CLUSTER_NAME" ]; then
    # Try to get from current context first
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
    if [[ "$CURRENT_CONTEXT" =~ ^kind-(.+)$ ]]; then
        DETECTED_CLUSTER="${BASH_REMATCH[1]}"
    else
        # Fallback: get first Kind cluster
        DETECTED_CLUSTER=$(kind get clusters 2>/dev/null | head -n 1)
    fi
    CLUSTER_NAME="${DETECTED_CLUSTER}"
fi

# Final fallback if still empty
CLUSTER_NAME="${CLUSTER_NAME:-ml-cluster}"

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  Current Context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    echo "  ARGOCD_NAMESPACE: $ARGOCD_NAMESPACE"
    echo "  JENKINS_NAMESPACE: $JENKINS_NAMESPACE"
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

# Determine environment (default to all)
ENVIRONMENT=${1:-all}

print_blue "Environment: ${ENVIRONMENT}"
print_blue "Cluster: ${CLUSTER_NAME}"
echo ""

# ========================================
# 🔧 Determine namespaces and releases based on environment
# ========================================
NAMESPACES_TO_DELETE=()
HELM_RELEASES=()  # Array of "release:namespace" pairs

case "$ENVIRONMENT" in
    dev)
        NAMESPACES_TO_DELETE=("data-dev")
        HELM_RELEASES=("jeffrey-epstein-files-dev:data-dev")
        print_blue "🎯 Targeting DEV environment (data-dev namespace)"
        echo ""
        ;;
    staging)
        NAMESPACES_TO_DELETE=("data-staging")
        HELM_RELEASES=("jeffrey-epstein-files-staging:data-staging")
        print_blue "🎯 Targeting STAGING environment (data-staging namespace)"
        echo ""
        ;;
    production)
        NAMESPACES_TO_DELETE=("data-production")
        HELM_RELEASES=("jeffrey-epstein-files-production:data-production")
        print_blue "🎯 Targeting PRODUCTION environment (data-production namespace)"
        echo ""
        ;;
    all)
        NAMESPACES_TO_DELETE=("data-dev" "data-staging" "data-production" "ml-pipeline" "data" "default")
        # Collect all jeffrey-epstein-files-related Helm releases dynamically
        print_blue "🔍 Scanning for all jeffrey-epstein-files Helm releases..."
        FOUND_RELEASES=false
        while IFS= read -r line; do
            RELEASE_NAME=$(echo "$line" | awk '{print $1}')
            NAMESPACE=$(echo "$line" | awk '{print $2}')
            if [[ "$RELEASE_NAME" =~ jeffrey-epstein-files ]]; then
                HELM_RELEASES+=("$RELEASE_NAME:$NAMESPACE")
                echo "  Found: $RELEASE_NAME in namespace $NAMESPACE"
                FOUND_RELEASES=true
            fi
        done < <(helm list --all-namespaces 2>/dev/null | tail -n +2)
        
        if [ "$FOUND_RELEASES" = false ]; then
            echo "  No jeffrey-epstein-files Helm releases found"
        fi
        print_blue "🎯 Targeting ALL environments"
        echo ""
        ;;
    *)
        print_red "❌ Invalid environment: $ENVIRONMENT"
        echo "Valid options: dev, staging, production, all"
        echo ""
        echo "Usage: $0 [dev|staging|production|all]"
        echo ""
        echo "Examples:"
        echo "  $0 dev         # Delete only dev environment"
        echo "  $0 staging     # Delete only staging environment"
        echo "  $0 production  # Delete only production environment"
        echo "  $0 all         # Delete all environments"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Step 1: Remove ArgoCD Applications
# -----------------------------------------------------------------------------
print_blue "🔍 Step 1: Checking for ArgoCD applications..."
if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_yellow "⚠️  ArgoCD is installed. Checking for managed applications..."
    
    # Delete ArgoCD applications based on environment
    if kubectl get crd applications.argoproj.io &>/dev/null 2>&1; then
        if [ "$ENVIRONMENT" = "all" ]; then
            # Delete all applications
            APP_COUNT=$(kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
            if [ "$APP_COUNT" -gt 0 ]; then
                echo "Found $APP_COUNT ArgoCD application(s). Removing all..."
                kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --timeout=60s 2>/dev/null || true
                print_green "✅ All ArgoCD applications removed"
            else
                print_green "✅ No ArgoCD applications to remove"
            fi
        else
            # Delete specific environment application
            APP_NAME="jeffrey-epstein-files-${ENVIRONMENT}"
            if kubectl get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
                echo "Removing ArgoCD application: $APP_NAME..."
                kubectl delete application "$APP_NAME" -n "$ARGOCD_NAMESPACE" --timeout=60s 2>/dev/null || true
                print_green "✅ ArgoCD application $APP_NAME removed"
            else
                print_green "✅ No ArgoCD application found for $ENVIRONMENT"
            fi
        fi
    else
        print_yellow "⚠️  ArgoCD CRD not found, skipping application cleanup"
    fi
    echo ""
else
    print_yellow "⚠️  ArgoCD not installed"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 2: Uninstall Helm releases
# -----------------------------------------------------------------------------
print_blue "📦 Step 2: Uninstalling Helm releases..."

RELEASES_REMOVED=()

if [ ${#HELM_RELEASES[@]} -gt 0 ]; then
    for release_info in "${HELM_RELEASES[@]}"; do
        RELEASE_NAME="${release_info%%:*}"
        NAMESPACE="${release_info##*:}"
        
        if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
            echo "Uninstalling $RELEASE_NAME from namespace $NAMESPACE..."
            helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --timeout 60s 2>/dev/null || {
                print_yellow "  ⚠️  Failed to uninstall $RELEASE_NAME, will force delete namespace"
            }
            RELEASES_REMOVED+=("$RELEASE_NAME ($NAMESPACE)")
        else
            print_yellow "⚠️  Release $RELEASE_NAME not found in namespace $NAMESPACE"
        fi
    done
    
    if [ ${#RELEASES_REMOVED[@]} -gt 0 ]; then
        print_green "✅ Helm releases removed:"
        for release in "${RELEASES_REMOVED[@]}"; do
            echo "   - $release"
        done
        echo ""
    else
        print_yellow "⚠️  No matching Helm releases found"
        echo ""
    fi
else
    print_yellow "⚠️  No Helm releases configured for cleanup"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 3: Delete application namespaces
# -----------------------------------------------------------------------------
print_blue "🗑️  Step 3: Deleting application namespaces..."

DELETED_NAMESPACES=()

for ns in "${NAMESPACES_TO_DELETE[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "Deleting namespace: $ns..."
        kubectl delete namespace "$ns" --timeout=60s 2>/dev/null &
        DELETED_NAMESPACES+=("$ns")
    fi
done

# Wait for all namespace deletions to complete
if [ ${#DELETED_NAMESPACES[@]} -gt 0 ]; then
    wait
    print_green "✅ Application namespaces deleted: ${DELETED_NAMESPACES[*]}"
    echo ""
else
    print_yellow "⚠️  No application namespaces to delete"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 4: Remove Jenkins (Optional - only when cleaning all)
# -----------------------------------------------------------------------------
if [ "$ENVIRONMENT" = "all" ]; then
    print_blue "🔧 Step 4: Jenkins cleanup..."
    if kubectl get namespace "$JENKINS_NAMESPACE" &>/dev/null; then
        echo "Jenkins is installed"
        read -p "Remove Jenkins? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "Removing Jenkins..."
            kubectl delete namespace "$JENKINS_NAMESPACE" --timeout=120s
            print_green "✅ Jenkins removed"
            echo ""
        else
            print_yellow "ℹ️  Keeping Jenkins"
            echo ""
        fi
    else
        print_green "✅ Jenkins not installed"
        echo ""
    fi
else
    print_blue "🔧 Step 4: Skipping Jenkins cleanup (only removed with 'all')"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 5: Remove ArgoCD (Optional - only when cleaning all)
# -----------------------------------------------------------------------------
if [ "$ENVIRONMENT" = "all" ]; then
    print_blue "🔧 Step 5: ArgoCD cleanup..."
    if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
        echo "ArgoCD is installed"
        read -p "Remove ArgoCD? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "Removing ArgoCD..."
            
            # Step 1: Delete all ArgoCD applications (prevents finalizer issues)
            echo "Deleting ArgoCD applications..."
            if kubectl get crd applications.argoproj.io &>/dev/null; then
                for app in $(kubectl get applications -n "$ARGOCD_NAMESPACE" -o name 2>/dev/null); do
                    echo "  Removing finalizers from $app..."
                    kubectl patch $app -n "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
                done
                kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --timeout=10s 2>/dev/null || true
            fi
            
            # Step 2: Delete CRDs (so their finalizers don't block namespace deletion)
            echo "Deleting ArgoCD CRDs..."
            kubectl delete crd applications.argoproj.io --timeout=10s 2>/dev/null || true
            kubectl delete crd applicationsets.argoproj.io --timeout=10s 2>/dev/null || true
            kubectl delete crd appprojects.argoproj.io --timeout=10s 2>/dev/null || true
            
            # Step 3: Force delete all resources in namespace
            echo "Force deleting all resources in $ARGOCD_NAMESPACE namespace..."
            kubectl delete all --all -n "$ARGOCD_NAMESPACE" --force --grace-period=0 --timeout=10s 2>/dev/null || true
            
            # Step 4: Remove namespace finalizers (this is the key!)
            echo "Removing namespace finalizers..."
            kubectl patch namespace "$ARGOCD_NAMESPACE" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || {
                # Fallback: try with metadata finalizers
                kubectl patch namespace "$ARGOCD_NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            }
            
            # Step 5: Delete the namespace (should be instant now)
            echo "Deleting namespace..."
            kubectl delete namespace "$ARGOCD_NAMESPACE" --timeout=5s 2>/dev/null || true
            
            # Step 6: Verify deletion
            sleep 2
            if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
                print_yellow "⚠️  Namespace still exists, trying API finalization..."
                
                # Last resort: Direct API call to remove finalizers
                if command -v jq &>/dev/null; then
                    kubectl get namespace "$ARGOCD_NAMESPACE" -o json 2>/dev/null | \
                      jq '.spec.finalizers = []' | \
                      kubectl replace --raw /api/v1/namespaces/"$ARGOCD_NAMESPACE"/finalize -f - 2>/dev/null || true
                else
                    print_red "❌ jq not installed, cannot force finalization"
                    echo "Install with: brew install jq"
                    echo "Then run: kubectl get namespace $ARGOCD_NAMESPACE -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$ARGOCD_NAMESPACE/finalize -f -"
                fi
                
                sleep 2
            fi
            
            # Final check
            if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
                print_red "❌ ArgoCD namespace still exists (stuck in Terminating)"
                echo ""
                echo "Manual cleanup required:"
                echo "  1. Install jq: brew install jq"
                echo "  2. Run: kubectl get namespace $ARGOCD_NAMESPACE -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$ARGOCD_NAMESPACE/finalize -f -"
                echo "  3. Or edit manually: kubectl edit namespace $ARGOCD_NAMESPACE (remove finalizers section)"
            else
                print_green "✅ ArgoCD removed"
            fi
            echo ""
        else
            print_yellow "ℹ️  Keeping ArgoCD"
            echo ""
        fi
    else
        print_green "✅ ArgoCD not installed"
        echo ""
    fi
else
    print_blue "🔧 Step 5: Skipping ArgoCD cleanup (only removed with 'all')"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 6: Clean up metrics server (optional - only when cleaning all)
# -----------------------------------------------------------------------------
if [ "$ENVIRONMENT" = "all" ]; then
    print_blue "📊 Step 6: Checking for metrics server..."
    METRICS_REMOVED=false

    if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        read -p "Remove metrics server? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Removing metrics server..."
            kubectl delete deployment metrics-server -n kube-system --timeout=60s 2>/dev/null || true
            kubectl delete service metrics-server -n kube-system --timeout=60s 2>/dev/null || true
            kubectl delete apiservice v1beta1.metrics.k8s.io --timeout=60s 2>/dev/null || true
            METRICS_REMOVED=true
            print_green "✅ Metrics server removed"
            echo ""
        else
            print_yellow "ℹ️  Keeping metrics server"
            echo ""
        fi
    else
        print_green "✅ Metrics server not installed"
        echo ""
    fi
else
    print_blue "📊 Step 6: Skipping metrics server cleanup (only removed with 'all')"
    echo ""
    METRICS_REMOVED=false
fi

# -----------------------------------------------------------------------------
# Step 7: Summary
# -----------------------------------------------------------------------------
print_green "✅ Cleanup complete!"
echo ""
echo "=========================================="
echo "📝 What was removed:"
echo "=========================================="

if [ "$ENVIRONMENT" = "all" ]; then
    echo "  ✅ All ArgoCD applications"
else
    echo "  ✅ ArgoCD application: jeffrey-epstein-files-${ENVIRONMENT}"
fi

if [ ${#RELEASES_REMOVED[@]} -gt 0 ]; then
    echo "  ✅ Helm releases:"
    for release in "${RELEASES_REMOVED[@]}"; do
        echo "     - $release"
    done
fi

if [ ${#DELETED_NAMESPACES[@]} -gt 0 ]; then
    echo "  ✅ Namespaces: ${DELETED_NAMESPACES[*]}"
fi

if [ "$ENVIRONMENT" = "all" ] && [ "$METRICS_REMOVED" = true ]; then
    echo "  ✅ Metrics server"
fi
echo ""

# Check what's still installed
PRESERVED=()
kubectl get namespace "$JENKINS_NAMESPACE" &>/dev/null && PRESERVED+=("Jenkins")
kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null && PRESERVED+=("ArgoCD")

# Check remaining application namespaces
for ns in "data-dev" "data-staging" "data-production" "data" "default"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        # Check if namespace has jeffrey-epstein-files resources
        if kubectl get pods -n "$ns" 2>/dev/null | grep -q jeffrey-epstein-files; then
            PRESERVED+=("$ns (has jeffrey-epstein-files resources)")
        fi
    fi
done

if [ ${#PRESERVED[@]} -gt 0 ]; then
    echo "=========================================="
    echo "📝 What was PRESERVED:"
    echo "=========================================="
    for item in "${PRESERVED[@]}"; do
        echo "  ✅ $item"
    done
    echo "  ⚠️  Kind cluster '$CLUSTER_NAME'"
    echo "  ⚠️  Data directories: $PROJECT_ROOT/data/, $PROJECT_ROOT/models/"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 8: Delete Kind cluster (optional - only when cleaning all)
# -----------------------------------------------------------------------------
if [ "$ENVIRONMENT" = "all" ]; then
    echo "=========================================="
    echo "🔥 Delete Kind Cluster?"
    echo "=========================================="
    
    # Show all available Kind clusters
    AVAILABLE_CLUSTERS=$(kind get clusters 2>/dev/null)
    if [ -n "$AVAILABLE_CLUSTERS" ]; then
        echo "Available Kind clusters:"
        echo "$AVAILABLE_CLUSTERS" | while read -r cluster; do
            if [ "$cluster" = "$CLUSTER_NAME" ]; then
                echo "  → $cluster (will be deleted)"
            else
                echo "    $cluster"
            fi
        done
        echo ""
    fi
    
    read -p "Do you want to delete the Kind cluster '$CLUSTER_NAME'? (y/N): " -n 1 -r
    echo

    DELETE_DATA=false

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
            echo "Deleting Kind cluster '$CLUSTER_NAME'..."
            kind delete cluster --name "$CLUSTER_NAME"
            print_green "✅ Kind cluster deleted!"
            echo ""
            
            # -----------------------------------------------------------------------------
            # Step 9: Delete data directories (optional)
            # -----------------------------------------------------------------------------
            echo "=========================================="
            echo "🗑️  Delete Data Directories?"
            echo "=========================================="
            echo "This will permanently delete:"
            echo "  - $PROJECT_ROOT/data/ (MongoDB, Redis data)"
            echo "  - $PROJECT_ROOT/models/ (ML models)"
            echo "  - $PROJECT_ROOT/tmp/ (Temporary files)"
            echo ""
            read -p "Delete data directories? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Deleting data directories..."
                [ -d "$PROJECT_ROOT/data" ] && rm -rf "$PROJECT_ROOT/data" && echo "  ✅ Deleted data/"
                [ -d "$PROJECT_ROOT/models" ] && rm -rf "$PROJECT_ROOT/models" && echo "  ✅ Deleted models/"
                [ -d "$PROJECT_ROOT/tmp" ] && rm -rf "$PROJECT_ROOT/tmp" && echo "  ✅ Deleted tmp/"
                DELETE_DATA=true
                print_green "✅ Data directories deleted!"
                echo ""
            else
                print_yellow "ℹ️  Keeping data directories"
                echo ""
            fi
        else
            print_yellow "⚠️  Kind cluster '$CLUSTER_NAME' not found"
            if [ -n "$AVAILABLE_CLUSTERS" ]; then
                echo ""
                echo "Available clusters to delete:"
                echo "$AVAILABLE_CLUSTERS" | while read -r cluster; do
                    echo "  kind delete cluster --name $cluster"
                done
            fi
            echo ""
        fi
    else
        print_yellow "ℹ️  Keeping Kind cluster"
        echo ""
    fi
else
    print_blue "🔥 Skipping cluster deletion (only removed with 'all')"
    echo ""
    DELETE_DATA=false
fi

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
echo "=========================================="
echo "✅ Destroy Script Complete"
echo "=========================================="
echo ""

# Check if any Kind cluster still exists
REMAINING_CLUSTERS=$(kind get clusters 2>/dev/null)
if [ -n "$REMAINING_CLUSTERS" ]; then
    echo "📋 Current state:"
    echo "$REMAINING_CLUSTERS" | while read -r cluster; do
        CONTEXT_CLUSTER=$(kubectl config current-context 2>/dev/null | sed 's/kind-//' || echo "")
        if [ "$cluster" = "$CONTEXT_CLUSTER" ]; then
            echo "  ✅ Kind cluster '$cluster' is running (current context)"
        else
            echo "  ✅ Kind cluster '$cluster' is running"
        fi
    done
    
    # Only check namespaces if we're still connected to a cluster
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        # Check what's still running
        kubectl get namespace "$JENKINS_NAMESPACE" &>/dev/null 2>&1 && echo "  ✅ Jenkins is still installed"
        kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null 2>&1 && echo "  ✅ ArgoCD is still installed"
        
        # Check remaining environments
        for env_ns in "data-dev" "data-staging" "data-production" "data" "default"; do
            if kubectl get namespace "$env_ns" &>/dev/null 2>&1; then
                POD_COUNT=$(kubectl get pods -n "$env_ns" 2>/dev/null | grep -c "jeffrey-epstein-files" || echo "0")
                if [ "$POD_COUNT" -gt 0 ]; then
                    echo "  ⚠️  $env_ns namespace has $POD_COUNT jeffrey-epstein-files pod(s) still running"
                fi
            fi
        done
    fi
    
    echo ""
    echo "To recreate the application:"
    echo "  cd cli"
    
    # Suggest appropriate command based on environment
    if [ "$ENVIRONMENT" = "all" ]; then
        if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null 2>&1; then
            echo "  ./deploy-with-argocd.sh dev        # Deploy dev"
            echo "  ./deploy-with-argocd.sh staging    # Deploy staging"
            echo "  ./deploy-with-argocd.sh production # Deploy production"
        else
            echo "  ./setup-complete-cicd.sh  # (to reinstall Jenkins + ArgoCD)"
            echo "  ./deploy-with-argocd.sh dev   # (then deploy your app)"
        fi
    else
        echo "  ./deploy-with-helm.sh $ENVIRONMENT"
        echo "  or"
        echo "  ./deploy-with-argocd.sh $ENVIRONMENT"
    fi
else
    echo "📋 Current state:"
    echo "  ❌ All Kind clusters deleted"
    if [ "$DELETE_DATA" = true ]; then
        echo "  ❌ Data directories deleted"
    else
        echo "  ✅ Data directories preserved"
    fi
    echo ""
    echo "To recreate everything:"
    echo "  1. Create cluster and setup CI/CD:"
    echo "     ./cli/setup-complete-cicd.sh"
    echo "  2. Deploy your app:"
    echo "     ./cli/deploy-with-argocd.sh $ENVIRONMENT"
fi

echo ""