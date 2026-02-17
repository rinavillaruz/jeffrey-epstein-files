#!/bin/bash

set -e  # Exit on any error

echo "🧹 Uninstalling ArgoCD from Kubernetes..."

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
# 🧭 Define directories
# -----------------------------------------------------------------------------
TMP_DIR="$PROJECT_ROOT/tmp"
VALUES_FILE="$TMP_DIR/argocd-values.yaml"

# -----------------------------------------------------------------------------
# Step 1: Check if ArgoCD namespace exists
# -----------------------------------------------------------------------------
print_blue "🔍 Step 1: Checking if ArgoCD is installed..."
if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_yellow "⚠️  ArgoCD namespace not found. Nothing to uninstall."
    exit 0
fi

print_green "✅ ArgoCD installation found."
echo ""

# -----------------------------------------------------------------------------
# Step 2: Check for existing ArgoCD applications
# -----------------------------------------------------------------------------
print_blue "📋 Step 2: Checking for managed applications..."
APPS_COUNT=$(kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | xargs)

if [ "$APPS_COUNT" -gt 0 ]; then
    print_yellow "⚠️  Found ${APPS_COUNT} application(s) managed by ArgoCD:"
    kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | awk '{print "   - " $1}'
    echo ""
    print_yellow "Note: Deleting applications will NOT delete your actual workloads."
    print_yellow "Your pods, services, etc. will continue running in their namespaces."
    echo ""
    
    read -p "Do you want to delete ArgoCD applications? (recommended) (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Deleting ArgoCD applications..."
        kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --timeout=60s 2>/dev/null || true
        print_green "✅ Applications deleted."
        echo ""
    else
        print_yellow "⚠️  Skipping application deletion. They may become orphaned resources."
        echo ""
    fi
else
    print_green "✅ No applications found."
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 3: Confirm uninstall
# -----------------------------------------------------------------------------
print_red "⚠️  WARNING: This will permanently delete ArgoCD and all its configuration."
read -p "Are you sure you want to uninstall ArgoCD? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_yellow "🚫 Uninstall cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# Step 4: Uninstall Helm release
# -----------------------------------------------------------------------------
print_blue "🧩 Step 4: Uninstalling Helm release 'argocd'..."
if helm status argocd -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    helm uninstall argocd -n "$ARGOCD_NAMESPACE"
    print_green "✅ Helm release removed."
    echo ""
else
    print_yellow "⚠️  Helm release not found. Skipping."
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 5: Clean up Custom Resource Definitions (CRDs)
# -----------------------------------------------------------------------------
print_blue "🧹 Step 5: Cleaning up ArgoCD CRDs..."
echo "Removing ArgoCD Custom Resource Definitions..."

CRDS=$(kubectl get crd 2>/dev/null | grep argoproj.io | awk '{print $1}')
if [ -z "$CRDS" ]; then
    print_yellow "⚠️  No ArgoCD CRDs found."
    echo ""
else
    echo "$CRDS" | xargs kubectl delete crd 2>/dev/null || true
    print_green "✅ CRDs cleaned up."
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 6: Clean up cluster-wide resources
# -----------------------------------------------------------------------------
print_blue "🔧 Step 6: Cleaning up cluster-wide resources..."

# Clean up ClusterRoles
echo "Checking for ArgoCD ClusterRoles..."
CLUSTER_ROLES=$(kubectl get clusterrole 2>/dev/null | grep argocd | awk '{print $1}')
if [ -n "$CLUSTER_ROLES" ]; then
    echo "$CLUSTER_ROLES" | xargs kubectl delete clusterrole 2>/dev/null || true
    print_green "✅ ClusterRoles removed."
else
    print_yellow "⚠️  No ArgoCD ClusterRoles found."
fi

# Clean up ClusterRoleBindings
echo "Checking for ArgoCD ClusterRoleBindings..."
CLUSTER_ROLE_BINDINGS=$(kubectl get clusterrolebinding 2>/dev/null | grep argocd | awk '{print $1}')
if [ -n "$CLUSTER_ROLE_BINDINGS" ]; then
    echo "$CLUSTER_ROLE_BINDINGS" | xargs kubectl delete clusterrolebinding 2>/dev/null || true
    print_green "✅ ClusterRoleBindings removed."
    echo ""
else
    print_yellow "⚠️  No ArgoCD ClusterRoleBindings found."
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 7: Delete ArgoCD namespace
# -----------------------------------------------------------------------------
print_blue "🗑️  Step 7: Deleting ArgoCD namespace..."
echo "This may take 30-60 seconds..."

# Delete namespace with timeout
kubectl delete namespace "$ARGOCD_NAMESPACE" --timeout=120s 2>/dev/null || {
    print_yellow "⚠️  Namespace deletion taking longer than expected..."
    echo "Checking for stuck resources..."
    
    # Force remove finalizers (try both methods)
    if command -v jq &> /dev/null; then
        echo "Using jq to remove finalizers..."
        kubectl get namespace "$ARGOCD_NAMESPACE" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/$ARGOCD_NAMESPACE/finalize" -f - 2>/dev/null || true
    else
        echo "Using kubectl patch to remove finalizers..."
        kubectl patch namespace "$ARGOCD_NAMESPACE" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    fi
    
    echo "Waiting for namespace deletion..."
    kubectl wait --for=delete namespace/"$ARGOCD_NAMESPACE" --timeout=60s || {
        print_red "❌ Namespace deletion failed."
        echo ""
        echo "Manual cleanup commands:"
        echo "  # Check stuck resources:"
        echo "  kubectl get all -n $ARGOCD_NAMESPACE"
        echo ""
        echo "  # Force remove finalizers:"
        echo "  kubectl patch namespace $ARGOCD_NAMESPACE -p '{\"spec\":{\"finalizers\":[]}}' --type=merge"
        echo ""
        echo "  # Delete namespace:"
        echo "  kubectl delete namespace $ARGOCD_NAMESPACE --grace-period=0 --force"
        exit 1
    }
}

print_green "✅ Namespace deleted."
echo ""

# -----------------------------------------------------------------------------
# Step 8: Clean up temporary files
# -----------------------------------------------------------------------------
print_blue "🧽 Step 8: Cleaning up temporary files..."
if [[ -f "$VALUES_FILE" ]]; then
    rm -f "$VALUES_FILE"
    print_green "✅ Removed temporary ArgoCD values file."
else
    print_yellow "⚠️  No temporary file found. Skipping."
fi
echo ""

# -----------------------------------------------------------------------------
# Step 9: Optional Helm repo cleanup
# -----------------------------------------------------------------------------
print_blue "🧹 Step 9: Optional Helm repo cleanup..."
read -p "Do you also want to remove the Argo Helm repo? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    helm repo remove argo 2>/dev/null || true
    print_green "✅ Argo Helm repo removed."
else
    print_yellow "ℹ️  Keeping Argo Helm repo for future use."
fi

# -----------------------------------------------------------------------------
# Step 10: Verification
# -----------------------------------------------------------------------------
echo ""
print_blue "🔍 Step 10: Verifying uninstall..."

# Check namespace
if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_red "❌ ArgoCD namespace still exists!"
    exit 1
else
    print_green "✅ ArgoCD namespace successfully removed."
fi

# Check Helm release
if helm status argocd -n "$ARGOCD_NAMESPACE" &>/dev/null; then
    print_red "❌ Helm release still exists!"
    exit 1
else
    print_green "✅ Helm release successfully removed."
fi

# Check CRDs
REMAINING_CRDS=$(kubectl get crd 2>/dev/null | grep argoproj.io | wc -l)
if [ "$REMAINING_CRDS" -gt 0 ]; then
    print_yellow "⚠️  Warning: ${REMAINING_CRDS} ArgoCD CRD(s) still present"
else
    print_green "✅ All ArgoCD CRDs removed."
fi

# Check cluster-wide resources
REMAINING_CLUSTER_RESOURCES=$(kubectl get clusterrole,clusterrolebinding 2>/dev/null | grep argocd | wc -l)
if [ "$REMAINING_CLUSTER_RESOURCES" -gt 0 ]; then
    print_yellow "⚠️  Warning: ${REMAINING_CLUSTER_RESOURCES} cluster-wide resource(s) still present"
else
    print_green "✅ All cluster-wide resources removed."
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
print_green "✅ ArgoCD has been fully uninstalled from your cluster."
echo ""
echo "=========================================="
echo "📝 What was removed:"
echo "=========================================="
echo "  ✅ ArgoCD server, controller, and repo server"
echo "  ✅ ArgoCD namespace and all resources"
echo "  ✅ Helm release 'argocd'"
echo "  ✅ ArgoCD Custom Resource Definitions (CRDs)"
echo "  ✅ ArgoCD ClusterRoles and ClusterRoleBindings"
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "  ✅ Argo Helm repository"
fi
echo "=========================================="
echo "📝 What was NOT affected:"
echo "=========================================="
echo "  ✅ Your applications (still running in all environments)"
echo "     - data-dev applications (still running)"
echo "     - data-staging applications (still running)"
echo "     - data-production applications (still running)"
echo "  ✅ Your Git repository"
echo "  ✅ Your Kubernetes cluster"
echo "  ✅ All environment namespaces and their resources"
echo ""
echo "Note: Removing ArgoCD only removes the GitOps controller,"
echo "not the applications it was managing. Your apps continue"
echo "running in dev, staging, and production namespaces."
echo ""
echo "=========================================="
echo "📝 To reinstall ArgoCD:"
echo "=========================================="
echo "  ./cli/install-argocd.sh"
echo ""
echo "To restore application management:"
echo "  kubectl apply -f $PROJECT_ROOT/argocd-apps/"
echo ""