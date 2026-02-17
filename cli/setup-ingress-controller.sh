#!/bin/bash
# One-time setup: Install nginx Ingress Controller

set -e

# ========================================
# 🎨 Colors for output
# ========================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_green() { echo -e "${GREEN}$1${NC}"; }
print_blue() { echo -e "${BLUE}$1${NC}"; }

print_blue "🌐 Installing Ingress Controller..."

# Check if already installed
if kubectl get namespace ingress-nginx &> /dev/null; then
    print_green "✅ Ingress Controller already installed"
    exit 0
fi

# Install nginx ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for ready
print_blue "⏳ Waiting for Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

print_green "✅ Ingress Controller installed and ready!"
echo ""
echo "You can now access services via:"
echo "  http://localhost/api"
echo "  http://localhost/jupyter"