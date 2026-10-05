# List recipes
default:
    @just --list

# Install the git hooks (pre-commit and commit-msg)
hooks:
    pre-commit install

# Run every pre-commit check on all files
lint:
    pre-commit run --all-files

# Kube context of the local k3d cluster
context := "k3d-llmops"

# Git revision ArgoCD deploys from; must be pushed (REVISION=my-branch just up)
revision := env("REVISION", "main")

# Create the local k3d cluster (local/k3d.yaml)
cluster-up:
    k3d cluster create --config local/k3d.yaml
    @echo "Cluster ready, context {{context}} (not made current)"

# Delete the local k3d cluster and its registry
cluster-down:
    k3d cluster delete --config local/k3d.yaml

# Check that the local cluster is healthy (nodes, system pods, registry)
cluster-check:
    scripts/cluster-check.sh {{context}}

# Install ArgoCD on a cluster and give it the root Application (any cluster: k3d, minikube, k3s)
bootstrap ctx=context env="local" rev=revision:
    scripts/bootstrap.sh {{ctx}} {{env}} {{rev}}

# Print the ArgoCD admin password and open the UI on http://localhost:8080 (port-forward)
argocd-ui ctx=context:
    @kubectl --context {{ctx}} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo " (user admin)"
    kubectl --context {{ctx}} -n argocd port-forward service/argocd-server 8080:80

# Start the platform locally: k3d cluster, then ArgoCD deploys everything from Git
up: cluster-up (bootstrap context "local" revision)

# Stop the platform
down: cluster-down

# Run the tests against the local cluster
test: cluster-check
    scripts/argocd-check.sh {{context}}
    scripts/selfheal-check.sh {{context}}
