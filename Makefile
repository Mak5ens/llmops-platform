.DEFAULT_GOAL := help
.PHONY: help hooks lint up down test

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-8s %s\n", $$1, $$2}'

hooks: ## Install the git hooks (pre-commit and commit-msg)
	pre-commit install

lint: ## Run every pre-commit check on all files
	pre-commit run --all-files

up: ## Start the stack locally
	@echo "Not implemented yet: see LAB-123 (reproducible local k3d cluster)" && exit 1

down: ## Stop the stack
	@echo "Not implemented yet: see LAB-123 (reproducible local k3d cluster)" && exit 1

test: ## Run the tests
	@echo "Not implemented yet: see LAB-123" && exit 1
