# List recipes
default:
    @just --list

# Install the git hooks (pre-commit and commit-msg)
hooks:
    pre-commit install

# Run every pre-commit check on all files
lint:
    pre-commit run --all-files

# Start the stack locally
up:
    @echo "Not implemented yet: see LAB-123 (reproducible local k3d cluster)" && exit 1

# Stop the stack
down:
    @echo "Not implemented yet: see LAB-123 (reproducible local k3d cluster)" && exit 1

# Run the tests
test:
    @echo "Not implemented yet: see LAB-123" && exit 1
