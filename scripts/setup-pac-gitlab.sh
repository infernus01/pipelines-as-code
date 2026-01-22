#!/usr/bin/env bash
#
# Setup script for Pipelines-as-Code (PAC) with GitLab webhook
#
# This script:
# 1. Creates a kind cluster (optional, if not already exists)
# 2. Installs Tekton Pipelines
# 3. Builds and deploys Pipelines-as-Code from local source using ko
# 4. Sets up gosmee for webhook forwarding
# 5. Creates namespace, secrets, and Repository CR for GitLab project
#
# Usage:
#   export GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"
#   ./setup-pac-gitlab.sh
#
# Or with custom values:
#   GITLAB_TOKEN="glpat-xxx" WEBHOOK_SECRET="mysecret123" \
#   GITLAB_REPO_URL="https://gitlab.com/infernus01/test-ok-to-test" \
#   ./setup-pac-gitlab.sh
#
# To deploy from local source (requires ko, may have compatibility issues):
#   PAC_DEPLOY_MODE=local ./setup-pac-gitlab.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - customize these or set via environment variables
GITLAB_REPO_URL="${GITLAB_REPO_URL:-https://gitlab.com/infernus01/test-ok-to-test}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-mysecret123}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
NAMESPACE="${NAMESPACE:-pac-test}"
CLUSTER_NAME="${CLUSTER_NAME:-pac-cluster}"
SKIP_CLUSTER_CREATE="${SKIP_CLUSTER_CREATE:-false}"
SKIP_TEKTON_INSTALL="${SKIP_TEKTON_INSTALL:-false}"
SKIP_PAC_INSTALL="${SKIP_PAC_INSTALL:-false}"

# Tekton and PAC versions
TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-latest}"
PAC_VERSION="${PAC_VERSION:-stable}"

# Set to "local" to build from local source with ko, or "remote" to use official release
PAC_DEPLOY_MODE="${PAC_DEPLOY_MODE:-remote}"

# Gosmee configuration
USE_GOSMEE="${USE_GOSMEE:-true}"
GOSMEE_URL="${GOSMEE_URL:-}"

# Derived values
REPO_NAME=$(basename "${GITLAB_REPO_URL}")

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

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing=()
    
    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi
    
    if ! command -v kind &> /dev/null; then
        missing+=("kind")
    fi
    
    # ko is only required for local builds
    if [[ "${PAC_DEPLOY_MODE}" == "local" ]] && ! command -v ko &> /dev/null; then
        missing+=("ko")
    fi
    
    if [[ -z "${GITLAB_TOKEN}" ]]; then
        log_error "GITLAB_TOKEN environment variable is required!"
        echo ""
        echo "Please create a GitLab Personal Access Token with 'api' scope:"
        echo "  https://gitlab.com/-/user_settings/personal_access_tokens"
        echo ""
        echo "Then run:"
        echo "  export GITLAB_TOKEN=\"glpat-xxxxxxxxxxxx\""
        echo "  ./setup-pac-gitlab.sh"
        exit 1
    fi
    log_info "Using GitLab token: ${GITLAB_TOKEN:0:10}..."
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install missing tools:"
        for tool in "${missing[@]}"; do
            case $tool in
                kubectl)
                    echo "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
                    ;;
                kind)
                    echo "  - kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
                    ;;
                ko)
                    echo "  - ko: https://ko.build/install/ (brew install ko)"
                    ;;
            esac
        done
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

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
        
        # Create kind config - using ports >= 1024 for rootless container compatibility
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
    
    # Set kubectl context
    kubectl config use-context "kind-${CLUSTER_NAME}"
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
}

install_tekton() {
    log_step "Installing Tekton Pipelines..."
    
    if [[ "${SKIP_TEKTON_INSTALL}" == "true" ]]; then
        log_info "Skipping Tekton installation (SKIP_TEKTON_INSTALL=true)"
        return
    fi
    
    # Check if Tekton is already installed
    if kubectl get namespace tekton-pipelines &>/dev/null; then
        log_info "Tekton Pipelines namespace exists, checking deployment..."
        if kubectl get deployment tekton-pipelines-controller -n tekton-pipelines &>/dev/null; then
            log_success "Tekton Pipelines already installed"
            return
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

install_pac() {
    log_step "Installing Pipelines-as-Code..."
    
    if [[ "${SKIP_PAC_INSTALL}" == "true" ]]; then
        log_info "Skipping PAC installation (SKIP_PAC_INSTALL=true)"
        return
    fi
    
    # Check if PAC is already installed and running
    if kubectl get namespace pipelines-as-code &>/dev/null; then
        if kubectl get deployment pipelines-as-code-controller -n pipelines-as-code &>/dev/null; then
            local ready
            ready=$(kubectl get deployment pipelines-as-code-controller -n pipelines-as-code -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "$ready" == "1" ]]; then
                log_success "Pipelines-as-Code already installed and running"
                return
            fi
        fi
    fi
    
    if [[ "${PAC_DEPLOY_MODE}" == "local" ]]; then
        install_pac_local
    else
        install_pac_remote
    fi
}

install_pac_remote() {
    log_info "Installing Pipelines-as-Code ${PAC_VERSION} from remote release..."
    
    # Clean up any existing broken installation
    kubectl delete namespace pipelines-as-code --wait=true 2>/dev/null || true
    
    kubectl apply -f "https://raw.githubusercontent.com/openshift-pipelines/pipelines-as-code/${PAC_VERSION}/release.k8s.yaml"
    
    log_info "Waiting for PAC to be ready..."
    kubectl wait --for=condition=Available deployment/pipelines-as-code-controller \
        -n pipelines-as-code --timeout=300s
    kubectl wait --for=condition=Available deployment/pipelines-as-code-watcher \
        -n pipelines-as-code --timeout=300s
    kubectl wait --for=condition=Available deployment/pipelines-as-code-webhook \
        -n pipelines-as-code --timeout=300s
    
    log_success "Pipelines-as-Code installed from remote release"
}

install_pac_local() {
    log_info "Building and deploying PAC from local source..."
    log_warning "Note: Local builds may have compatibility issues with some container runtimes (e.g., rootless podman)"
    
    # Check if ko is installed
    if ! command -v ko &> /dev/null; then
        log_error "ko is required for local builds. Install: brew install ko"
        log_info "Falling back to remote release..."
        install_pac_remote
        return
    fi
    
    # Get the script directory and project root
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root
    project_root="$(cd "${script_dir}/.." && pwd)"
    
    log_info "Building and deploying PAC from: ${project_root}"
    
    # Clean up any existing broken installation
    kubectl delete namespace pipelines-as-code --wait=true 2>/dev/null || true
    
    # Set up ko registry - use kind's local registry
    export KO_DOCKER_REPO="${KO_DOCKER_REPO:-kind.local}"
    export KIND_CLUSTER_NAME="${CLUSTER_NAME}"
    
    log_info "Using KO_DOCKER_REPO=${KO_DOCKER_REPO}"
    log_info "Using KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}"
    
    # Build and deploy using ko
    cd "${project_root}"
    
    log_info "Applying PAC config with ko..."
    if ! ko apply -f config -B; then
        log_error "ko apply failed. Falling back to remote release..."
        install_pac_remote
        return
    fi
    
    log_info "Waiting for PAC to be ready..."
    if ! kubectl wait --for=condition=Available deployment/pipelines-as-code-controller \
        -n pipelines-as-code --timeout=120s; then
        log_error "PAC pods failed to start. This may be a Go runtime compatibility issue."
        log_info "Falling back to remote release..."
        install_pac_remote
        return
    fi
    
    kubectl wait --for=condition=Available deployment/pipelines-as-code-watcher \
        -n pipelines-as-code --timeout=120s
    kubectl wait --for=condition=Available deployment/pipelines-as-code-webhook \
        -n pipelines-as-code --timeout=120s
    
    log_success "Pipelines-as-Code deployed from local source"
}

setup_gosmee() {
    log_step "Setting up webhook forwarding with gosmee..."
    
    if [[ "${USE_GOSMEE}" != "true" ]]; then
        log_info "Skipping gosmee setup (USE_GOSMEE=false)"
        return
    fi
    
    # Generate a gosmee URL if not provided
    if [[ -z "${GOSMEE_URL}" ]]; then
        log_info "Generating gosmee webhook URL..."
        # Use hook.pipelinesascode.com for a unique URL
        GOSMEE_URL="https://hook.pipelinesascode.com/$(openssl rand -hex 8)"
        log_info "Generated gosmee URL: ${GOSMEE_URL}"
    fi
    
    # Check if gosmee deployment already exists
    if kubectl get deployment gosmee-client -n pipelines-as-code &>/dev/null; then
        log_info "Gosmee deployment already exists, updating..."
        kubectl delete deployment gosmee-client -n pipelines-as-code --ignore-not-found
    fi
    
    # Deploy gosmee client
    log_info "Deploying gosmee client..."
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
            requests:
              memory: "64Mi"
              cpu: "50m"
EOF
    
    log_info "Waiting for gosmee to be ready..."
    kubectl wait --for=condition=Available deployment/gosmee-client \
        -n pipelines-as-code --timeout=120s
    
    log_success "Gosmee webhook forwarder deployed"
    log_info "Webhook URL for GitLab: ${GOSMEE_URL}"
    
    # Export for later use
    export GOSMEE_URL
}

create_namespace_and_secrets() {
    log_step "Creating namespace and secrets..."
    
    # Create namespace
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_info "Namespace '${NAMESPACE}' already exists"
    else
        log_info "Creating namespace '${NAMESPACE}'..."
        kubectl create namespace "${NAMESPACE}"
        log_success "Namespace created"
    fi
    
    # Create GitLab token secret
    log_info "Creating GitLab token secret..."
    kubectl create secret generic gitlab-token \
        --namespace "${NAMESPACE}" \
        --from-literal=token="${GITLAB_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "GitLab token secret created"
    
    # Create webhook secret
    log_info "Creating webhook secret..."
    kubectl create secret generic gitlab-webhook-secret \
        --namespace "${NAMESPACE}" \
        --from-literal=webhook.secret="${WEBHOOK_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "Webhook secret created"
}

create_repository_cr() {
    log_step "Creating Repository CR..."
    
    log_info "Creating Repository CR for ${GITLAB_REPO_URL}..."
    
    cat <<EOF | kubectl apply -f -
---
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: ${REPO_NAME}
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
    
    log_success "Repository CR created"
    
    # Verify
    kubectl get repository -n "${NAMESPACE}"
}

print_gitlab_webhook_instructions() {
    log_step "GitLab Webhook Configuration Instructions"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configure GitLab Webhook"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Go to your GitLab repository:"
    echo "   ${GITLAB_REPO_URL}/-/hooks"
    echo ""
    echo "2. Click 'Add new webhook' and configure:"
    echo ""
    echo "   URL: ${GOSMEE_URL}"
    echo ""
    echo "   Secret token: ${WEBHOOK_SECRET}"
    echo ""
    echo "   Trigger events (select these):"
    echo "   ☑ Push events"
    echo "   ☑ Merge request events"
    echo "   ☑ Comments"
    echo "   ☑ Tag push events"
    echo ""
    echo "   SSL verification: ☑ Enable (recommended)"
    echo ""
    echo "3. Click 'Add webhook'"
    echo ""
    echo "4. Test the webhook by clicking 'Test' → 'Push events'"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

print_summary() {
    log_step "Setup Complete! 🎉"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Cluster:           kind-${CLUSTER_NAME}"
    echo "  GitLab Repo:       ${GITLAB_REPO_URL}"
    echo "  Namespace:         ${NAMESPACE}"
    echo "  Repository CR:     ${REPO_NAME}"
    echo "  Webhook URL:       ${GOSMEE_URL}"
    echo "  Webhook Secret:    ${WEBHOOK_SECRET}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Useful commands:"
    echo ""
    echo "  # Watch PAC controller logs"
    echo "  kubectl logs -n pipelines-as-code deployment/pipelines-as-code-controller -f"
    echo ""
    echo "  # Check Repository CR"
    echo "  kubectl get repository -n ${NAMESPACE}"
    echo ""
    echo "  # Check PipelineRuns"
    echo "  kubectl get pipelineruns -n ${NAMESPACE}"
    echo ""
    echo "  # Describe Repository"
    echo "  kubectl describe repository ${REPO_NAME} -n ${NAMESPACE}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

cleanup() {
    echo ""
    log_step "Cleanup instructions"
    echo ""
    echo "To remove everything created by this script:"
    echo ""
    echo "  # Delete the namespace (removes secrets and Repository CR)"
    echo "  kubectl delete namespace ${NAMESPACE}"
    echo ""
    echo "  # Delete the kind cluster"
    echo "  kind delete cluster --name ${CLUSTER_NAME}"
    echo ""
    echo "  # Remove the GitLab webhook manually from:"
    echo "  ${GITLAB_REPO_URL}/-/hooks"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║  Pipelines-as-Code Setup for GitLab                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_prerequisites
    create_kind_cluster
    install_tekton
    install_pac
    setup_gosmee
    create_namespace_and_secrets
    create_repository_cr
    print_gitlab_webhook_instructions
    print_summary
    
    # Trap for showing cleanup on script interrupt
    trap cleanup EXIT
}

# Run main
main "$@"
