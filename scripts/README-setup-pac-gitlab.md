# PAC Setup Script for GitLab

This script automates the setup of Pipelines-as-Code (PAC) in a Kind cluster with GitLab webhook integration.

## Target Repository

The script is pre-configured for: <https://gitlab.com/infernus01/test-ok-to-test>

## Prerequisites

1. **kubectl** - Kubernetes CLI
2. **kind** - Kubernetes in Docker
3. **GitLab Personal Access Token** with `api` scope

### Creating a GitLab Token

1. Go to: <https://gitlab.com/-/user_settings/personal_access_tokens>
2. Click "Add new token"
3. Configure:
   - **Token name**: `pac-controller`
   - **Expiration date**: Set as needed
   - **Scopes**: Select `api`
4. Click "Create personal access token"
5. **Copy and save the token immediately**

## Quick Start

```bash
# Set your GitLab token
export GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"

# Run the setup script
./setup-pac-gitlab.sh
```

## Configuration Options

All options can be set via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_TOKEN` | (required) | GitLab Personal Access Token with `api` scope |
| `GITLAB_REPO_URL` | `https://gitlab.com/infernus01/test-ok-to-test` | GitLab repository URL |
| `WEBHOOK_SECRET` | `mysecret123` | Webhook validation secret |
| `NAMESPACE` | `pac-test` | Kubernetes namespace for pipelines |
| `CLUSTER_NAME` | `pac-cluster` | Kind cluster name |
| `SKIP_CLUSTER_CREATE` | `false` | Skip Kind cluster creation |
| `SKIP_TEKTON_INSTALL` | `false` | Skip Tekton Pipelines installation |
| `SKIP_PAC_INSTALL` | `false` | Skip PAC installation |
| `USE_GOSMEE` | `true` | Use gosmee for webhook forwarding |
| `GOSMEE_URL` | (auto-generated) | Custom gosmee webhook URL |
| `TEKTON_PIPELINE_VERSION` | `latest` | Tekton Pipelines version |
| `PAC_VERSION` | `stable` | PAC version (`stable` or `nightly`) |

### Example with Custom Values

```bash
GITLAB_TOKEN="glpat-xxx" \
WEBHOOK_SECRET="my-custom-secret" \
NAMESPACE="my-ci-namespace" \
./setup-pac-gitlab.sh
```

## What the Script Does

1. **Creates Kind Cluster** - Sets up a local Kubernetes cluster with port mappings
2. **Installs Tekton Pipelines** - Core CI/CD engine
3. **Installs Pipelines-as-Code** - GitOps-style pipeline automation
4. **Deploys Gosmee** - Webhook forwarder for local development
5. **Creates Namespace** - Isolated namespace for your pipelines
6. **Creates Secrets**:
   - `gitlab-token` - GitLab API authentication
   - `gitlab-webhook-secret` - Webhook payload validation
7. **Creates Repository CR** - Links GitLab repo to PAC

## After Running the Script

### 1. Configure GitLab Webhook

The script will print instructions with:
- Webhook URL (gosmee URL)
- Secret token
- Events to enable

Go to: `<your-repo-url>/-/hooks` and add the webhook.

### 2. Add .tekton Directory to Your Repository

Copy the sample `.tekton` files to your GitLab repository:

```bash
# Clone your GitLab repo
git clone https://gitlab.com/infernus01/test-ok-to-test.git
cd test-ok-to-test

# Copy sample tekton files
mkdir -p .tekton
cp /path/to/pipelines-as-code/scripts/sample-tekton/*.yaml .tekton/

# Commit and push
git add .tekton/
git commit -m "Add .tekton directory with PAC pipelines"
git push origin main
```

### 3. Test the Integration

Create a merge request to trigger the pipeline:

```bash
git checkout -b test-pac
echo "# Test change" >> README.md
git add README.md
git commit -m "Test PAC integration"
git push origin test-pac
```

Then create a merge request in GitLab.

## Useful Commands

```bash
# Watch PAC controller logs
kubectl logs -n pipelines-as-code deployment/pipelines-as-code-controller -f

# Check Repository CR
kubectl get repository -n pac-test

# Check PipelineRuns
kubectl get pipelineruns -n pac-test

# Watch PipelineRuns
kubectl get pipelineruns -n pac-test -w

# Describe a PipelineRun
kubectl describe pipelinerun <name> -n pac-test

# Check secrets
kubectl get secrets -n pac-test
```

## Cleanup

```bash
# Delete namespace (removes Repository CR and secrets)
kubectl delete namespace pac-test

# Delete the Kind cluster
kind delete cluster --name pac-cluster

# Remove webhook from GitLab (manual step)
# Go to: <your-repo-url>/-/hooks
```

## Troubleshooting

### Webhook not received

1. Check gosmee is running:
   ```bash
   kubectl get pods -n pipelines-as-code -l app=gosmee-client
   kubectl logs -n pipelines-as-code deployment/gosmee-client
   ```

2. Check GitLab webhook "Recent deliveries" for errors

3. Ensure webhook events are enabled (Push, MR, Comments)

### Pipeline not triggered

1. Check PAC controller logs:
   ```bash
   kubectl logs -n pipelines-as-code deployment/pipelines-as-code-controller --tail=100
   ```

2. Verify Repository CR is correct:
   ```bash
   kubectl get repository -n pac-test -o yaml
   ```

3. Ensure `.tekton/` directory exists in the repository with valid PipelineRun files

### Authentication errors

1. Verify the GitLab token has `api` scope
2. Check the token is correctly set in the secret:
   ```bash
   kubectl get secret gitlab-token -n pac-test -o jsonpath='{.data.token}' | base64 -d
   ```

### Webhook secret mismatch

1. Ensure the secret in GitLab webhook matches:
   ```bash
   kubectl get secret gitlab-webhook-secret -n pac-test -o jsonpath='{.data.webhook\.secret}' | base64 -d
   ```
