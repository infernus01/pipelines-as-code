#!/usr/bin/env bash
#
# Setup script for Pipelines-as-Code (PAC) with BOTH GitLab AND GitHub webhooks
#
# This script sets up:
# 1. Kind cluster with Tekton Pipelines and PAC
# 2. Gosmee for webhook forwarding
# 3. GitLab repository: https://gitlab.com/infernus01/test-ok-to-test
# 4. GitHub repository: https://github.com/infernus01/git-repo-1
#
# Usage:
#   export GITLAB_TOKEN="glpat-xxxxxxxxxxxx"
#   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
#   ./setup-pac-all.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# CONFIGURATION - All values hardcoded for convenience
# ============================================================================

# Cluster configuration
CLUSTER_NAME="${CLUSTER_NAME:-pac-cluster}"
NAMESPACE="${NAMESPACE:-pac-test}"

# Shared webhook secret (same for both providers)
WEBHOOK_SECRET="${WEBHOOK_SECRET:-mysecret123}"

# GitLab configuration
GITLAB_REPO_URL="${GITLAB_REPO_URL:-https://gitlab.com/infernus01/test-ok-to-test}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

# GitHub configuration
GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/infernus01/git-repo-1}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Tekton and PAC versions
TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-latest}"
PAC_VERSION="${PAC_VERSION:-stable}"
PAC_DEPLOY_MODE="${PAC_DEPLOY_MODE:-remote}"

# Gosmee configuration
GOSMEE_URL="${GOSMEE_URL:-}"

# Skip flags
SKIP_CLUSTER_CREATE="${SKIP_CLUSTER_CREATE:-false}"
SKIP_TEKTON_INSTALL="${SKIP_TEKTON_INSTALL:-false}"
SKIP_PAC_INSTALL="${SKIP_PAC_INSTALL:-false}"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "\n${GREEN}==>${NC} ${BLUE}$1${NC}"
}

log_provider() {
    echo -e "\n${CYAN}━━━ $1 ━━━${NC}"
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing=()
    
    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi
    
    if ! command -v kind &> /dev/null; then
        missing+=("kind")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    # Check for required tokens
    if [[ -z "${GITLAB_TOKEN}" ]]; then
        log_error "GITLAB_TOKEN environment variable is required!"
        echo ""
        echo "Create a GitLab PAT with 'api' scope at:"
        echo "  https://gitlab.com/-/user_settings/personal_access_tokens"
        echo ""
        echo "Then: export GITLAB_TOKEN=\"glpat-xxxxxxxxxxxx\""
        exit 1
    fi
    
    if [[ -z "${GITHUB_TOKEN}" ]]; then
        log_error "GITHUB_TOKEN environment variable is required!"
        echo ""
        echo "Create a GitHub PAT with 'repo' scope at:"
        echo "  https://github.com/settings/tokens/new"
        echo ""
        echo "Then: export GITHUB_TOKEN=\"ghp_xxxxxxxxxxxx\""
        exit 1
    fi
    
    log_info "GitLab token: ${GITLAB_TOKEN:0:10}..."
    log_info "GitHub token: ${GITHUB_TOKEN:0:10}..."
    log_info "Webhook secret: ${WEBHOOK_SECRET}"
    
    log_success "All prerequisites satisfied"
}

# ============================================================================
# CLUSTER SETUP
# ============================================================================

create_kind_cluster() {
    log_step "Setting up Kind cluster..."
    
    if [[ "${SKIP_CLUSTER_CREATE}" == "true" ]]; then
        log_info "Skipping cluster creation (SKIP_CLUSTER_CREATE=true)"
        return
    fi
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Kind cluster '${CLUSTER_NAME}' already exists"
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || {
            log_warning "Cluster exists but not accessible, recreating..."
            kind delete cluster --name "${CLUSTER_NAME}"
        }
    fi
    
    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Creating Kind cluster '${CLUSTER_NAME}'..."
        
        cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8880
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
  - containerPort: 8080
    hostPort: 8080
    protocol: TCP
EOF
        log_success "Kind cluster created"
    else
        log_success "Using existing Kind cluster '${CLUSTER_NAME}'"
    fi
    
    kubectl config use-context "kind-${CLUSTER_NAME}"
    
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
}

# ============================================================================
# TEKTON INSTALLATION
# ============================================================================

install_tekton() {
    log_step "Installing Tekton Pipelines..."
    
    if [[ "${SKIP_TEKTON_INSTALL}" == "true" ]]; then
        log_info "Skipping Tekton installation"
        return
    fi
    
    if kubectl get namespace tekton-pipelines &>/dev/null; then
        if kubectl get deployment tekton-pipelines-controller -n tekton-pipelines &>/dev/null; then
            local ready
            ready=$(kubectl get deployment tekton-pipelines-controller -n tekton-pipelines -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "$ready" -ge "1" ]]; then
                log_success "Tekton Pipelines already installed and running"
                return
            fi
        fi
    fi
    
    log_info "Installing Tekton Pipelines ${TEKTON_PIPELINE_VERSION}..."
    kubectl apply --filename "https://storage.googleapis.com/tekton-releases/pipeline/${TEKTON_PIPELINE_VERSION}/release.yaml"
    
    log_info "Waiting for Tekton Pipelines to be ready..."
    kubectl wait --for=condition=Available deployment/tekton-pipelines-controller \
        -n tekton-pipelines --timeout=300s
    kubectl wait --for=condition=Available deployment/tekton-pipelines-webhook \
        -n tekton-pipelines --timeout=300s
    
    log_success "Tekton Pipelines installed"
}

# ============================================================================
# PAC INSTALLATION
# ============================================================================

install_pac() {
    log_step "Installing Pipelines-as-Code..."
    
    if [[ "${SKIP_PAC_INSTALL}" == "true" ]]; then
        log_info "Skipping PAC installation"
        return
    fi
    
    if kubectl get namespace pipelines-as-code &>/dev/null; then
        if kubectl get deployment pipelines-as-code-controller -n pipelines-as-code &>/dev/null; then
            local ready
            ready=$(kubectl get deployment pipelines-as-code-controller -n pipelines-as-code -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "$ready" -ge "1" ]]; then
                log_success "Pipelines-as-Code already installed and running"
                return
            fi
        fi
    fi
    
    log_info "Installing Pipelines-as-Code ${PAC_VERSION} from remote release..."
    
    kubectl delete namespace pipelines-as-code --wait=true 2>/dev/null || true
    
    kubectl apply -f "https://raw.githubusercontent.com/openshift-pipelines/pipelines-as-code/${PAC_VERSION}/release.k8s.yaml"
    
    log_info "Waiting for PAC to be ready..."
    kubectl wait --for=condition=Available deployment/pipelines-as-code-controller \
        -n pipelines-as-code --timeout=300s
    kubectl wait --for=condition=Available deployment/pipelines-as-code-watcher \
        -n pipelines-as-code --timeout=300s
    kubectl wait --for=condition=Available deployment/pipelines-as-code-webhook \
        -n pipelines-as-code --timeout=300s
    
    log_success "Pipelines-as-Code installed"
}

# ============================================================================
# GOSMEE SETUP
# ============================================================================

setup_gosmee() {
    log_step "Setting up webhook forwarding with gosmee..."
    
    if [[ -z "${GOSMEE_URL}" ]]; then
        GOSMEE_URL="https://hook.pipelinesascode.com/$(openssl rand -hex 8)"
        log_info "Generated gosmee URL: ${GOSMEE_URL}"
    fi
    
    kubectl delete deployment gosmee-client -n pipelines-as-code --ignore-not-found 2>/dev/null
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gosmee-client
  namespace: pipelines-as-code
  labels:
    app: gosmee-client
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gosmee-client
  template:
    metadata:
      labels:
        app: gosmee-client
    spec:
      containers:
        - name: gosmee-client
          image: 'ghcr.io/chmouel/gosmee:main'
          args:
            - client
            - '${GOSMEE_URL}'
            - 'http://pipelines-as-code-controller.pipelines-as-code.svc.cluster.local:8080'
          resources:
            limits:
              memory: "128Mi"
              cpu: "100m"
EOF
    
    log_info "Waiting for gosmee to be ready..."
    kubectl wait --for=condition=Available deployment/gosmee-client \
        -n pipelines-as-code --timeout=120s
    
    log_success "Gosmee deployed"
    
    export GOSMEE_URL
}

# ============================================================================
# NAMESPACE AND SECRETS
# ============================================================================

create_namespace() {
    log_step "Creating namespace..."
    
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Namespace '${NAMESPACE}' already exists"
    else
        kubectl create namespace "${NAMESPACE}"
        log_success "Namespace '${NAMESPACE}' created"
    fi
}

setup_gitlab_secrets() {
    log_provider "Setting up GitLab secrets"
    
    kubectl create secret generic gitlab-token \
        --namespace "${NAMESPACE}" \
        --from-literal=token="${GITLAB_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "GitLab token secret created"
    
    kubectl create secret generic gitlab-webhook-secret \
        --namespace "${NAMESPACE}" \
        --from-literal=webhook.secret="${WEBHOOK_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "GitLab webhook secret created"
}

setup_github_secrets() {
    log_provider "Setting up GitHub secrets"
    
    kubectl create secret generic github-token \
        --namespace "${NAMESPACE}" \
        --from-literal=token="${GITHUB_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "GitHub token secret created"
    
    kubectl create secret generic github-webhook-secret \
        --namespace "${NAMESPACE}" \
        --from-literal=webhook.secret="${WEBHOOK_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "GitHub webhook secret created"
}

# ============================================================================
# REPOSITORY CRs
# ============================================================================

create_gitlab_repository() {
    log_provider "Creating GitLab Repository CR"
    
    local repo_name
    repo_name=$(basename "${GITLAB_REPO_URL}")
    
    cat <<EOF | kubectl apply -f -
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: gitlab-${repo_name}
  namespace: ${NAMESPACE}
spec:
  url: "${GITLAB_REPO_URL}"
  git_provider:
    type: "gitlab"
    secret:
      name: gitlab-token
      key: token
    webhook_secret:
      name: gitlab-webhook-secret
      key: webhook.secret
EOF
    
    log_success "GitLab Repository CR 'gitlab-${repo_name}' created"
}

create_github_repository() {
    log_provider "Creating GitHub Repository CR"
    
    local repo_name
    repo_name=$(basename "${GITHUB_REPO_URL}")
    
    cat <<EOF | kubectl apply -f -
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: github-${repo_name}
  namespace: ${NAMESPACE}
spec:
  url: "${GITHUB_REPO_URL}"
  git_provider:
    secret:
      name: github-token
      key: token
    webhook_secret:
      name: github-webhook-secret
      key: webhook.secret
EOF
    
    log_success "GitHub Repository CR 'github-${repo_name}' created"
}

# ============================================================================
# SUMMARY AND INSTRUCTIONS
# ============================================================================

print_webhook_instructions() {
    log_step "Webhook Configuration Instructions"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║  GITLAB WEBHOOK CONFIGURATION                                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. Go to: ${GITLAB_REPO_URL}/-/hooks"
    echo ""
    echo "  2. Add new webhook with:"
    echo "     URL:          ${GOSMEE_URL}"
    echo "     Secret token: ${WEBHOOK_SECRET}"
    echo "     Events:       ☑ Push  ☑ Merge request  ☑ Comments  ☑ Tag push"
    echo ""
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║  GITHUB WEBHOOK CONFIGURATION                                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. Go to: ${GITHUB_REPO_URL}/settings/hooks/new"
    echo ""
    echo "  2. Add new webhook with:"
    echo "     Payload URL:   ${GOSMEE_URL}"
    echo "     Content type:  application/json"
    echo "     Secret:        ${WEBHOOK_SECRET}"
    echo "     Events:        ☑ Pull requests  ☑ Pushes  ☑ Issue comments"
    echo "                    ☑ Check runs  ☑ Check suites"
    echo ""
}

print_summary() {
    log_step "Setup Complete! 🎉"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Cluster:         kind-${CLUSTER_NAME}"
    echo "  Namespace:       ${NAMESPACE}"
    echo "  Webhook URL:     ${GOSMEE_URL}"
    echo "  Webhook Secret:  ${WEBHOOK_SECRET}"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────────────┐"
    echo "  │ GITLAB                                                                  │"
    echo "  ├─────────────────────────────────────────────────────────────────────────┤"
    echo "  │ Repository:    ${GITLAB_REPO_URL}"
    echo "  │ Token Secret:  gitlab-token"
    echo "  │ Webhook Secret: gitlab-webhook-secret"
    echo "  │ Repository CR: gitlab-$(basename ${GITLAB_REPO_URL})"
    echo "  └─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────────────┐"
    echo "  │ GITHUB                                                                  │"
    echo "  ├─────────────────────────────────────────────────────────────────────────┤"
    echo "  │ Repository:    ${GITHUB_REPO_URL}"
    echo "  │ Token Secret:  github-token"
    echo "  │ Webhook Secret: github-webhook-secret"
    echo "  │ Repository CR: github-$(basename ${GITHUB_REPO_URL})"
    echo "  └─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Useful commands:"
    echo ""
    echo "  # List all Repository CRs"
    echo "  kubectl get repository -n ${NAMESPACE}"
    echo ""
    echo "  # Watch PAC controller logs"
    echo "  kubectl logs -n pipelines-as-code deployment/pipelines-as-code-controller -f"
    echo ""
    echo "  # Check PipelineRuns"
    echo "  kubectl get pipelineruns -n ${NAMESPACE}"
    echo ""
    echo "  # List all secrets"
    echo "  kubectl get secrets -n ${NAMESPACE}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║  Pipelines-as-Code Setup for GitLab + GitHub                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_prerequisites
    
    # Infrastructure setup (shared)
    create_kind_cluster
    install_tekton
    install_pac
    setup_gosmee
    
    # Namespace (shared)
    create_namespace
    
    # GitLab setup
    setup_gitlab_secrets
    create_gitlab_repository
    
    # GitHub setup
    setup_github_secrets
    create_github_repository
    
    # Show results
    echo ""
    kubectl get repository -n "${NAMESPACE}"
    echo ""
    kubectl get secrets -n "${NAMESPACE}"
    
    print_webhook_instructions
    print_summary
}

# Run main
main "$@"
