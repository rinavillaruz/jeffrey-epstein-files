# 🎮 Jeffrey Epstein Files Platform

[![Deploy to Environment](https://github.com/rinavillaruz/jeffrey-epstein-files/actions/workflows/deploy.yaml/badge.svg?branch=dev)](https://github.com/rinavillaruz/jeffrey-epstein-files/actions/workflows/deploy.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=flat&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](https://www.docker.com/)

An enterprise-grade MLOps platform for Jeffrey Epstein files prediction, analysis, and data-driven insights. Built with production-ready infrastructure patterns including automated CI/CD, multi-environment deployments, and comprehensive observability.

---

## 📊 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│             Jeffrey Epstein Files Platform                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ Data Fetcher │  │  ML Trainer  │  │  API Service │          │
│  │   (Python)   │  │  (PyTorch)   │  │   (FastAPI)  │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                  │                  │                   │
│         └──────────────────┼──────────────────┘                  │
│                            │                                      │
│         ┌──────────────────┴──────────────────┐                 │
│         │                                      │                  │
│  ┌──────▼───────┐                    ┌────────▼────────┐        │
│  │   MongoDB    │                    │     Redis       │        │
│  │  (Database)  │                    │    (Cache)      │        │
│  └──────────────┘                    └─────────────────┘        │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Features

### Core Platform
- **🔄 Automated Data Pipeline** - Real-time data fetching and processing
- **🤖 ML Training Pipeline** - Automated model training and versioning with MLflow
- **⚡ REST API** - FastAPI-based inference service with async support
- **📊 Interactive Analysis** - Jupyter notebooks for data exploration

### DevOps & Infrastructure
- **☸️ Kubernetes Native** - Helm charts for declarative deployments
- **🔀 Multi-Environment** - Separate dev, staging, and production environments
- **🔄 GitOps Workflows** - Automated CI/CD with GitHub Actions and Jenkins
- **📦 Container Registry** - Multi-stage Docker builds optimized for production
- **🔍 Observability** - Comprehensive monitoring and alerting setup

### Production Ready
- **🛡️ High Availability** - Replicated services with auto-scaling
- **💾 Persistent Storage** - StatefulSets for databases with backup strategies
- **🔐 Security** - RBAC, secrets management, and network policies
- **📈 Scalability** - Horizontal pod autoscaling based on metrics

---

## 🏗️ Infrastructure

### Technology Stack

| Layer | Technology |
|-------|-----------|
| **Orchestration** | Kubernetes (Kind for local, EKS/GKE for cloud) |
| **Package Manager** | Helm 3 |
| **Container Runtime** | Docker with BuildKit |
| **CI/CD** | GitHub Actions (dev/staging), Jenkins (production) |
| **Database** | MongoDB 7.0 |
| **Cache** | Redis 7.2 |
| **ML Framework** | PyTorch, Scikit-learn |
| **API Framework** | FastAPI |
| **Monitoring** | Prometheus + Grafana (optional) |

### Kubernetes Architecture

```yaml
Namespaces:
  - data              # Production workloads
  - data-dev          # Development environment  
  - data-staging      # Staging environment

Services:
  - jeffrey-epstein-files-fetcher     # Data ingestion service
  - jeffrey-epstein-files-trainer     # ML training jobs
  - jeffrey-epstein-files-api         # REST API service
  - mongodb                           # Primary database
  - redis                             # Caching layer
  - jupyter                           # Analysis notebooks (dev only)
```

---

## 📦 Deployment

### Environments

| Environment | Branch | Namespace | Trigger | Approval |
|-------------|--------|-----------|---------|----------|
| **Development** | `dev` | `data-dev` | Auto on push | ❌ None |
| **Staging** | `staging` | `data-staging` | Auto on push | ❌ None |
| **Production** | `main` | `data` | Jenkins | ✅ Manual |

### Deployment Status

- **Dev:** ![Dev Status](https://img.shields.io/badge/dev-active-success)
- **Staging:** ![Staging Status](https://img.shields.io/badge/staging-active-success)
- **Production:** ![Production Status](https://img.shields.io/badge/production-stable-blue)

---

## 🛠️ Local Development

### Prerequisites

- Docker Desktop or Kind
- kubectl
- Helm 3
- Python 3.11+
- Git

---

## 🔧 Configuration

### Kubernetes Secrets

```bash
# Create MongoDB credentials
kubectl create secret generic mongodb-secret \
  --from-literal=username=admin \
  --from-literal=password=your-secure-password \
  -n data-dev

# Create Docker registry credentials (for private images)
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=docker.io \
  --docker-username=your-username \
  --docker-password=your-token \
  -n data-dev
```

---

## 📊 Monitoring & Observability

### Slack Notifications

The platform sends automated notifications to Slack:

| Channel | Purpose | Trigger |
|---------|---------|---------|
| `#github-deployments` | Dev/Staging deployments | GitHub Actions |
| `#jenkins-builds` | Production builds | Jenkins CI |

Notifications include:
- ✅ Deployment status (success/failure)
- ⏱️ Build duration
- 🏷️ Image tags (current & previous)
- 🔄 Rollback commands
- 📊 Monitoring dashboard links
- 👤 Author and commit information

### Health Checks

```bash
# API health endpoint
curl http://api-service:8000/health

# MongoDB connection
kubectl exec -it mongodb-0 -n data-dev -- mongosh --eval "db.adminCommand('ping')"

# Redis connection
kubectl exec -it redis-0 -n data-dev -- redis-cli ping
```

---

## 🔄 CI/CD Pipeline

### GitHub Actions Workflow (Dev/Staging)

**Triggers:** Push to `dev` or `staging` branches

**Pipeline Steps:**
1. 🔍 Checkout code
2. 🔐 Docker Hub login
3. 🐳 Build multi-stage Docker images (parallel)
   - Data Fetcher
   - ML Trainer
   - API Service
4. 📤 Push images with version tags + `:latest`
5. ⚓ Deploy to Kubernetes with Helm
6. 📢 Send Slack notification

Github runners: ./run.sh
Github runners persistent: 
```
./svc.sh install
./svc.sh start
./svc.sh status
```

**Image Tagging Strategy:**
```
Format: {env}-{run_number}-{git_sha}
Example: dev-42-a3f9c2d1
Also tagged as: dev-latest
```

### Jenkins Pipeline (Production)

**Triggers:** Push to `main` branch

**Pipeline Steps:**
1. 📦 Initialize build metadata
2. 🔔 Notify build start
3. 📥 Checkout code
4. 🧪 Run tests (pytest, flake8)
5. 🔐 Docker Hub login
6. 🐳 Build images (parallel)
7. 📤 Push with version + `:latest` tags
8. ⏸️ **Manual approval required**
9. 🚀 Deploy to production
10. ✅ Verify deployment
11. 📢 Send success/failure notification