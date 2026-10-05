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

# Start the platform locally (the ArgoCD bootstrap comes with LAB-124)
up: cluster-up

# Stop the platform
down: cluster-down

# Run the tests against the local cluster
test: cluster-check
