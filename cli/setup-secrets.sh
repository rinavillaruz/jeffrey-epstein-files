#!/bin/bash

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

print_blue "================================"
print_green "🔐 Secrets Setup for Jeffrey Epstein Files"
print_blue "================================"
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

# Configuration (with defaults)
JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-jenkins}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"
MONGODB_USERNAME="${MONGODB_USERNAME:-admin}"
MONGODB_PASSWORD="${MONGODB_PASSWORD:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
# OPENDOTA_API_KEY="${OPENDOTA_API_KEY:-}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-admin@example.com}"
SLACK_WEBHOOK_JENKINS="${SLACK_WEBHOOK_JENKINS:-}"
SLACK_WEBHOOK_GITHUB="${SLACK_WEBHOOK_GITHUB:-}"
# DOTA2_API_KEY="${DOTA2_API_KEY:-}"

# Detect if running non-interactively (from Skaffold, CI/CD, etc.)
if [ ! -t 0 ]; then
    NON_INTERACTIVE=true
    print_blue "Running in non-interactive mode (Skaffold/CI)"
else
    NON_INTERACTIVE=false
fi

# Debug mode
if [ "${DEBUG:-false}" = "true" ]; then
    echo "🐛 Debug - Configuration:"
    echo "  Project Root: $PROJECT_ROOT"
    echo "  JENKINS_NAMESPACE: $JENKINS_NAMESPACE"
    echo "  MONGODB_USERNAME: $MONGODB_USERNAME"
    echo "  GITHUB_USERNAME: $GITHUB_USERNAME"
    echo "  DOCKERHUB_USERNAME: $DOCKERHUB_USERNAME"
    echo "  NON_INTERACTIVE: $NON_INTERACTIVE"
    echo ""
fi

# Parse environment argument
ENVIRONMENT=${1:-dev}

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production|all)$ ]]; then
    print_red "❌ Invalid environment: $ENVIRONMENT"
    echo "Valid options: dev, staging, production, all"
    echo ""
    echo "Usage: $0 [dev|staging|production|all]"
    echo ""
    echo "Examples:"
    echo "  $0 dev         # Setup secrets for dev environment only"
    echo "  $0 staging     # Setup secrets for staging environment only"
    echo "  $0 production  # Setup secrets for production environment only"
    echo "  $0 all         # Setup secrets for all environments"
    exit 1
fi

echo -e "${BLUE}Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo ""

# ========================================
# 🔧 Determine namespaces based on environment
# ========================================
APP_NAMESPACES=()

case "$ENVIRONMENT" in
    dev)
        APP_NAMESPACES=("data-dev")
        print_blue "🎯 Setting up secrets for DEV environment"
        ;;
    staging)
        APP_NAMESPACES=("data-staging")
        print_blue "🎯 Setting up secrets for STAGING environment"
        ;;
    production)
        APP_NAMESPACES=("data-production")
        print_blue "🎯 Setting up secrets for PRODUCTION environment"
        ;;
    all)
        APP_NAMESPACES=("data-dev" "data-staging" "data-production")
        print_blue "🎯 Setting up secrets for ALL environments"
        ;;
esac

echo ""

# ========================================
# MongoDB Secrets (application namespaces)
# ========================================
print_blue "📦 MongoDB Credentials"
echo ""

if [ -n "$JENKINS_HOME" ]; then
    # Running in Jenkins - use environment variables
    echo "Running in Jenkins - using environment variables"
    MONGODB_USERNAME=${MONGODB_USERNAME:-admin}
    MONGODB_PASSWORD=${MONGODB_PASSWORD:-password123}
else
    # Running locally - use .env or prompt
    if [ -z "$MONGODB_PASSWORD" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            # Non-interactive mode (Skaffold/CI) - credentials must be in .env
            print_red "❌ Error: Running non-interactively but MONGODB_PASSWORD not set"
            echo ""
            echo "Please create $PROJECT_ROOT/.env file with:"
            echo "  MONGODB_USERNAME=admin"
            echo "  MONGODB_PASSWORD=your_password"
            echo ""
            echo "Or set environment variables before running."
            exit 1
        else
            # Interactive mode - prompt for credentials
            read -p "MongoDB username (default: admin): " INPUT_USERNAME
            MONGODB_USERNAME=${INPUT_USERNAME:-admin}
            
            read -sp "MongoDB password (default: changeme123): " INPUT_PASSWORD
            echo ""
            MONGODB_PASSWORD=${INPUT_PASSWORD:-changeme123}
        fi
    else
        echo "Using MongoDB credentials from .env"
    fi
fi

# Create MongoDB secrets in each target namespace
for NAMESPACE in "${APP_NAMESPACES[@]}"; do
    echo ""
    echo -e "${BLUE}Creating secrets in ${YELLOW}${NAMESPACE}${BLUE} namespace...${NC}"
    
    # Create namespace if doesn't exist
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    print_green "  ✓ Namespace ${NAMESPACE} created/verified"
    
    # Create MongoDB secret
    if kubectl get secret mongodb-secret -n "$NAMESPACE" &>/dev/null; then
        print_yellow "  ⚠️  mongodb-secret already exists in ${NAMESPACE}"
        if [ "$ENVIRONMENT" = "all" ] || [ "$NON_INTERACTIVE" = true ]; then
            # Auto-recreate when setting up all environments or in non-interactive mode
            kubectl delete secret mongodb-secret -n "$NAMESPACE"
            kubectl create secret generic mongodb-secret -n "$NAMESPACE" \
                --from-literal=username="$MONGODB_USERNAME" \
                --from-literal=password="$MONGODB_PASSWORD"
            print_green "  ✓ mongodb-secret recreated in ${NAMESPACE}"
        else
            read -p "  Recreate it? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                kubectl delete secret mongodb-secret -n "$NAMESPACE"
                kubectl create secret generic mongodb-secret -n "$NAMESPACE" \
                    --from-literal=username="$MONGODB_USERNAME" \
                    --from-literal=password="$MONGODB_PASSWORD"
                print_green "  ✓ mongodb-secret recreated in ${NAMESPACE}"
            else
                echo "  Keeping existing secret"
            fi
        fi
    else
        kubectl create secret generic mongodb-secret -n "$NAMESPACE" \
            --from-literal=username="$MONGODB_USERNAME" \
            --from-literal=password="$MONGODB_PASSWORD"
        print_green "  ✓ mongodb-secret created in ${NAMESPACE}"
    fi
    
    # Create Redis secret if password is set
    if [ -n "$REDIS_PASSWORD" ]; then
        if kubectl get secret redis-secret -n "$NAMESPACE" &>/dev/null; then
            print_yellow "  ⚠️  redis-secret already exists in ${NAMESPACE}"
            if [ "$ENVIRONMENT" = "all" ] || [ "$NON_INTERACTIVE" = true ]; then
                kubectl delete secret redis-secret -n "$NAMESPACE"
                kubectl create secret generic redis-secret -n "$NAMESPACE" \
                    --from-literal=password="$REDIS_PASSWORD"
                print_green "  ✓ redis-secret recreated in ${NAMESPACE}"
            fi
        else
            kubectl create secret generic redis-secret -n "$NAMESPACE" \
                --from-literal=password="$REDIS_PASSWORD"
            print_green "  ✓ redis-secret created in ${NAMESPACE}"
        fi
    fi
    
    # # Create OpenDota API secret if key is set
    # if [ -n "$OPENDOTA_API_KEY" ]; then
    #     if kubectl get secret opendota-secret -n "$NAMESPACE" &>/dev/null; then
    #         print_yellow "  ⚠️  opendota-secret already exists in ${NAMESPACE}"
    #         if [ "$ENVIRONMENT" = "all" ] || [ "$NON_INTERACTIVE" = true ]; then
    #             kubectl delete secret opendota-secret -n "$NAMESPACE"
    #             kubectl create secret generic opendota-secret -n "$NAMESPACE" \
    #                 --from-literal=apiKey="$OPENDOTA_API_KEY"
    #             print_green "  ✓ opendota-secret recreated in ${NAMESPACE}"
    #         fi
    #     else
    #         kubectl create secret generic opendota-secret -n "$NAMESPACE" \
    #             --from-literal=apiKey="$OPENDOTA_API_KEY"
    #         print_green "  ✓ opendota-secret created in ${NAMESPACE}"
    #     fi
    # fi
done

echo ""

# ========================================
# Jenkins Secrets (jenkins namespace) - Only for dev/all
# ========================================
if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "all" ]]; then
    print_blue "🤖 Jenkins/CI Credentials"
    echo ""
    
    # Skip Jenkins setup in non-interactive mode unless explicitly requested
    if [ "$NON_INTERACTIVE" = true ]; then
        print_yellow "⚠️  Skipping Jenkins secrets in non-interactive mode"
        echo ""
    else
        read -p "Setup Jenkins secrets? (Y/n): " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            # Create jenkins namespace if doesn't exist
            kubectl create namespace "$JENKINS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
            print_green "✓ Jenkins namespace created/verified"
            echo ""
            
            # ========================================
            # 1. Jenkins Admin Credentials
            # ========================================
            print_blue "1. Jenkins Admin Password"
            if [ -z "$JENKINS_ADMIN_PASSWORD" ]; then
                read -sp "Jenkins admin password (default: changeme): " INPUT_JENKINS_PASSWORD
                echo ""
                JENKINS_ADMIN_PASSWORD=${INPUT_JENKINS_PASSWORD:-changeme}
            else
                echo "Using Jenkins admin password from .env"
            fi
            
            kubectl create secret generic jenkins-admin-credentials \
                --from-literal=password="$JENKINS_ADMIN_PASSWORD" \
                -n "$JENKINS_NAMESPACE" \
                --dry-run=client -o yaml | kubectl apply -f -
            print_green "✓ jenkins-admin-credentials created"
            echo ""
            
            # ========================================
            # 2. GitHub Credentials
            # ========================================
            print_blue "2. GitHub Credentials"
            if [ -z "$GITHUB_USERNAME" ]; then
                read -p "GitHub username (optional, press Enter to skip): " GITHUB_USERNAME
            fi
            
            if [ -z "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
                read -sp "GitHub token (optional): " GITHUB_TOKEN
                echo ""
            fi
            
            if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_TOKEN" ]; then
                kubectl create secret generic github-credentials \
                    --from-literal=username="$GITHUB_USERNAME" \
                    --from-literal=token="$GITHUB_TOKEN" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ github-credentials created"
            else
                print_yellow "⚠️  GitHub credentials not provided - skipping"
            fi
            echo ""
            
            # ========================================
            # 3. Docker Hub Credentials
            # ========================================
            print_blue "3. Docker Hub Credentials"
            if [ -z "$DOCKERHUB_USERNAME" ]; then
                read -p "Docker Hub username (default: rinavillaruz): " INPUT_DOCKERHUB_USERNAME
                DOCKERHUB_USERNAME=${INPUT_DOCKERHUB_USERNAME:-rinavillaruz}
            else
                echo "Using Docker Hub username from .env: $DOCKERHUB_USERNAME"
            fi
            
            if [ -z "$DOCKERHUB_TOKEN" ]; then
                read -sp "Docker Hub token (optional, press Enter to skip): " DOCKERHUB_TOKEN
                echo ""
            fi
            
            # Create dockerhub-credentials (for CLI/API use)
            if [ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ]; then
                kubectl create secret generic dockerhub-credentials \
                    --from-literal=username="$DOCKERHUB_USERNAME" \
                    --from-literal=token="$DOCKERHUB_TOKEN" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ dockerhub-credentials created"
                
                # Create dockerhub-pull-secret (ImagePullSecret for pulling private images)
                kubectl create secret docker-registry dockerhub-pull-secret \
                    --docker-server=https://index.docker.io/v1/ \
                    --docker-username="$DOCKERHUB_USERNAME" \
                    --docker-password="$DOCKERHUB_TOKEN" \
                    --docker-email="$DOCKERHUB_EMAIL" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ dockerhub-pull-secret created"
            else
                print_yellow "⚠️  Docker Hub credentials not provided - skipping"
            fi
            echo ""
            
            # ========================================
            # 4. Slack Webhooks (Jenkins + GitHub Actions)
            # ========================================
            print_blue "4. Slack Webhooks"
            echo "  Two webhooks for channel separation:"
            echo "  - Jenkins → #jenkins-builds (production)"
            echo "  - GitHub Actions → #github-deployments (dev/staging)"
            echo ""
            
            JENKINS_WEBHOOK=""
            GITHUB_WEBHOOK=""
            
            # Check if webhooks are in .env
            if [ -n "$SLACK_WEBHOOK_JENKINS" ]; then
                JENKINS_WEBHOOK="$SLACK_WEBHOOK_JENKINS"
                echo "Using Jenkins webhook from .env"
            else
                read -p "Jenkins Slack Webhook URL (for #jenkins-builds): " JENKINS_WEBHOOK
            fi
            
            if [ -n "$SLACK_WEBHOOK_GITHUB" ]; then
                GITHUB_WEBHOOK="$SLACK_WEBHOOK_GITHUB"
                echo "Using GitHub Actions webhook from .env"
            else
                read -p "GitHub Actions Slack Webhook URL (for #github-deployments): " GITHUB_WEBHOOK
            fi
            
            if [ -n "$JENKINS_WEBHOOK" ] && [ -n "$GITHUB_WEBHOOK" ]; then
                # Create combined secret with both webhooks
                kubectl create secret generic slack-webhooks \
                    --from-literal=jenkins-webhook-url="$JENKINS_WEBHOOK" \
                    --from-literal=github-webhook-url="$GITHUB_WEBHOOK" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ slack-webhooks created with both Jenkins and GitHub webhooks"
                
                # Also create backward-compatible jenkins-slack-webhook (for existing setups)
                kubectl create secret generic jenkins-slack-webhook \
                    --from-literal=webhook-url="$JENKINS_WEBHOOK" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ jenkins-slack-webhook created (backward compatible)"
            elif [ -n "$JENKINS_WEBHOOK" ]; then
                # Only Jenkins webhook provided
                kubectl create secret generic jenkins-slack-webhook \
                    --from-literal=webhook-url="$JENKINS_WEBHOOK" \
                    -n "$JENKINS_NAMESPACE" \
                    --dry-run=client -o yaml | kubectl apply -f -
                print_green "✓ jenkins-slack-webhook created"
                print_yellow "⚠️  GitHub Actions webhook not provided"
            else
                print_yellow "⚠️  Slack webhooks not provided - skipping"
            fi
            echo ""
        fi
    fi
else
    print_blue "🤖 Skipping Jenkins secrets (only needed for dev/all)"
    echo ""
fi

# ========================================
# API Keys & External Services (Optional)
# ========================================
# if [ "$NON_INTERACTIVE" = false ]; then
#     print_blue "🔑 External API Keys (Optional)"
#     echo ""

#     read -p "Setup Dota2 API key? (y/N): " -n 1 -r
#     echo

#     if [[ $REPLY =~ ^[Yy]$ ]]; then
#         if [ -z "$DOTA2_API_KEY" ]; then
#             read -p "Dota2 API Key: " DOTA2_API_KEY
#         fi
        
#         if [ -n "$DOTA2_API_KEY" ]; then
#             # Create API key in each target namespace
#             for NAMESPACE in "${APP_NAMESPACES[@]}"; do
#                 kubectl create secret generic dota2-api-secret -n "$NAMESPACE" \
#                     --from-literal=api-key="$DOTA2_API_KEY" \
#                     --dry-run=client -o yaml | kubectl apply -f -
#                 print_green "✓ dota2-api-secret created in ${NAMESPACE}"
#             done
#         fi
#     fi
#     echo ""
# fi

# ========================================
# Summary
# ========================================
print_blue "================================"
print_green "✅ Secrets Setup Complete!"
print_blue "================================"
echo ""

# Show secrets in each namespace
for NAMESPACE in "${APP_NAMESPACES[@]}"; do
    echo -e "${BLUE}Secrets in ${YELLOW}${NAMESPACE}${BLUE} namespace:${NC}"
    kubectl get secrets -n "$NAMESPACE" 2>/dev/null | grep -E "mongodb-secret|redis-secret" || echo "  None"
    echo ""
done

if kubectl get namespace "$JENKINS_NAMESPACE" &>/dev/null; then
    echo -e "${BLUE}Secrets in ${YELLOW}${JENKINS_NAMESPACE}${BLUE} namespace:${NC}"
    kubectl get secrets -n "$JENKINS_NAMESPACE" 2>/dev/null | grep -E "jenkins-|github-|dockerhub-|slack-" || echo "  None"
    echo ""
fi

print_blue "================================"
print_blue "📋 Created Secrets Summary:"
print_blue "================================"
echo ""

# Check which secrets were created
SECRETS_CREATED=0

for NAMESPACE in "${APP_NAMESPACES[@]}"; do
    ENV_NAME=$(echo "$NAMESPACE" | sed 's/data-//')
    echo "${ENV_NAME} environment (${NAMESPACE}):"
    
    if kubectl get secret mongodb-secret -n "$NAMESPACE" &>/dev/null; then
        echo "  ✅ mongodb-secret"
        SECRETS_CREATED=$((SECRETS_CREATED + 1))
    fi
    if kubectl get secret redis-secret -n "$NAMESPACE" &>/dev/null; then
        echo "  ✅ redis-secret"
        SECRETS_CREATED=$((SECRETS_CREATED + 1))
    fi
    # if kubectl get secret opendota-secret -n "$NAMESPACE" &>/dev/null; then
    #     echo "  ✅ opendota-secret"
    #     SECRETS_CREATED=$((SECRETS_CREATED + 1))
    # fi
    # if kubectl get secret dota2-api-secret -n "$NAMESPACE" &>/dev/null; then
    #     echo "  ✅ dota2-api-secret"
    #     SECRETS_CREATED=$((SECRETS_CREATED + 1))
    # fi
    echo ""
done

if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "all" ]]; then
    if kubectl get namespace "$JENKINS_NAMESPACE" &>/dev/null; then
        echo "Jenkins namespace:"
        if kubectl get secret jenkins-admin-credentials -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ jenkins-admin-credentials"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        if kubectl get secret github-credentials -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ github-credentials"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        if kubectl get secret dockerhub-credentials -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ dockerhub-credentials"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        if kubectl get secret dockerhub-pull-secret -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ dockerhub-pull-secret"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        if kubectl get secret slack-webhooks -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ slack-webhooks (Jenkins + GitHub Actions)"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        if kubectl get secret jenkins-slack-webhook -n "$JENKINS_NAMESPACE" &>/dev/null; then
            echo "  ✅ jenkins-slack-webhook (backward compatible)"
            SECRETS_CREATED=$((SECRETS_CREATED + 1))
        fi
        echo ""
    fi
fi

print_green "Total secrets created: $SECRETS_CREATED"
echo ""

if [ "$NON_INTERACTIVE" = false ]; then
    print_blue "================================"
    print_yellow "📝 Next Steps:"
    print_blue "================================"
    echo ""

    case "$ENVIRONMENT" in
        dev)
            echo "  Deploy to dev:"
            echo "    ./cli/deploy-with-helm.sh dev"
            echo "  or"
            echo "    ./cli/deploy-with-argocd.sh dev"
            echo "  or with Skaffold:"
            echo "    skaffold dev"
            ;;
        staging)
            echo "  Deploy to staging:"
            echo "    ./cli/deploy-with-helm.sh staging"
            echo "  or"
            echo "    ./cli/deploy-with-argocd.sh staging"
            echo "  or with Skaffold:"
            echo "    skaffold run --profile=staging"
            ;;
        production)
            echo "  Deploy to production:"
            echo "    ./cli/deploy-with-helm.sh production"
            echo "  or"
            echo "    ./cli/deploy-with-argocd.sh production"
            echo "  or with Skaffold:"
            echo "    skaffold run --profile=production"
            ;;
        all)
            echo "  Deploy to each environment:"
            echo "    ./cli/deploy-with-helm.sh dev"
            echo "    ./cli/deploy-with-helm.sh staging"
            echo "    ./cli/deploy-with-helm.sh production"
            ;;
    esac
    echo ""
fi

print_green "🎉 Done!"