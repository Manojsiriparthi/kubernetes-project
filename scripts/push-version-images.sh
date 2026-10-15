#!/usr/bin/env bash
# Builds the frontend and backend images and pushes them to ECR with a fixed version tag, for example:
#   ./scripts/push-version-images.sh version1     (run on branch release/version1)
#   ./scripts/push-version-images.sh version2     (run on branch release/version2)
# The release branches' manifests already point at these tags, so Argo CD can pull them after the push.
# ECR tags are immutable: pushing the same tag twice fails, which protects a released version from being overwritten.
set -euo pipefail

TAG="${1:?Usage: $0 <tag>   e.g. version1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra"

# Repository addresses come from the Terraform outputs (the infrastructure must already exist).
REGION="$(terraform -chdir="${TF_DIR}" output -raw region)"
FRONTEND_REPO="$(terraform -chdir="${TF_DIR}" output -raw frontend_ecr_repository_url)"
BACKEND_REPO="$(terraform -chdir="${TF_DIR}" output -raw backend_ecr_repository_url)"

aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${FRONTEND_REPO%%/*}"

# The EKS nodes are x86_64, so build for that platform even on an ARM machine.
docker build --platform linux/amd64 -t "${BACKEND_REPO}:${TAG}" "${REPO_ROOT}/application/backend"
docker push "${BACKEND_REPO}:${TAG}"
docker build --platform linux/amd64 -t "${FRONTEND_REPO}:${TAG}" "${REPO_ROOT}/application/frontend"
docker push "${FRONTEND_REPO}:${TAG}"

echo "Pushed ${BACKEND_REPO}:${TAG} and ${FRONTEND_REPO}:${TAG}"
