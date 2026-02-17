#!/bin/bash
# Run ML Training Pipeline
# Triggers fetch → process → train jobs in Kubernetes

set -e

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
# Configuration
# ========================================
ENVIRONMENT=${1:-dev}
NAMESPACE="data-${ENVIRONMENT}"

print_blue "========================================="
print_blue "🤖 Jeffrey Epstein Files - ML Training Pipeline"
print_blue "========================================="
echo ""
print_blue "Environment: $ENVIRONMENT"
print_blue "Namespace: $NAMESPACE"
echo ""

# ========================================
# Check if namespace exists
# ========================================
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    print_red "❌ Namespace $NAMESPACE does not exist"
    echo "Please deploy the application first:"
    echo "  ./cli/deploy-with-helm.sh $ENVIRONMENT"
    exit 1
fi

# ========================================
# Run ML training jobs
# ========================================
print_blue "🚀 Starting ML training jobs..."
echo ""

# Determine directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" 2>/dev/null || PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
HELM_DIR="$PROJECT_ROOT/deploy/helm"

if [ ! -d "$HELM_DIR" ]; then
    print_red "❌ Cannot find Helm chart directory: $HELM_DIR"
    exit 1
fi

cd "$HELM_DIR"

# Check if values file exists
if [ ! -f "values-${ENVIRONMENT}.yaml" ]; then
    print_red "❌ Error: values-${ENVIRONMENT}.yaml not found!"
    exit 1
fi

# Run Helm upgrade with ML jobs enabled
print_blue "Deploying with ML jobs enabled..."
if helm upgrade jeffrey-epstein-files . \
  --namespace $NAMESPACE \
  --values values-${ENVIRONMENT}.yaml \
  --set mlFetcher.enabled=true \
  --set mlProcessor.enabled=true \
  --set mlTrainer.enabled=true \
  --wait=false; then
    print_green "✅ ML training jobs started"
else
    print_red "❌ Failed to start ML training jobs"
    exit 1
fi

echo ""
print_blue "========================================="
print_blue "📊 Job Status"
print_blue "========================================="
echo ""

# Wait a moment for jobs to be created
sleep 3

# Show job status
kubectl get jobs -n $NAMESPACE -l component=ml-pipeline

echo ""
print_blue "========================================="
print_blue "📝 Useful Commands"
print_blue "========================================="
echo ""
echo "Watch job status:"
echo "  kubectl get jobs -n $NAMESPACE -w"
echo ""
echo "View fetch logs:"
echo "  kubectl logs -n $NAMESPACE -l step=fetch -f"
echo ""
echo "View process logs:"
echo "  kubectl logs -n $NAMESPACE -l step=process -f"
echo ""
echo "View training logs:"
echo "  kubectl logs -n $NAMESPACE -l app=jeffrey-epstein-files-trainer -f"
echo ""
echo "View all ML pipeline logs:"
echo "  kubectl logs -n $NAMESPACE -l component=ml-pipeline -f --max-log-requests=10"
echo ""
echo "Check what's in storage:"
echo "  kubectl run pvc-check --rm -i --restart=Never --image=busybox -n $NAMESPACE \\"
echo "    --overrides='{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"ls -lh /data/; echo; ls -lh /models/\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"},{\"name\":\"models\",\"mountPath\":\"/models\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"jeffrey-epstein-files-trainer-training-data\"}},{\"name\":\"models\",\"persistentVolumeClaim\":{\"claimName\":\"jeffrey-epstein-files-trainer-models\"}}]}}'"
echo ""
echo "Delete old completed jobs:"
echo "  kubectl delete jobs -n $NAMESPACE -l component=ml-pipeline --field-selector status.successful=1"
echo ""