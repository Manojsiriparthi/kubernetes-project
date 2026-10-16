#!/usr/bin/env bash
# Deploy of the school-demo app.
#   1) Deploy : build both images, set their names in kubernetes/backend.yaml and frontend.yaml, kubectl apply kubernetes/
#               images are tagged and pushed to the ECR repositories created by infra.sh.
#   2) Destroy: kubectl delete kubernetes/ (the namespace goes too)
# Usage: ./scripts/app.sh [1|2]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${REPO_ROOT}/kubernetes"
PROJECT_NAME="${PROJECT_NAME:-school-demo}"
NAMESPACE="school-demo"
REGION="${AWS_REGION:-us-east-1}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

preflight() {
  for tool in docker kubectl git aws; do
    command -v "${tool}" >/dev/null || die "'${tool}' is not installed."
  done
  kubectl version >/dev/null 2>&1 || die "kubectl cannot reach a cluster."
}

do_deploy() {
  local tag registry backend_image frontend_image
  # Repositories are immutable, so every run needs a new tag.
  tag="$(date +%Y%m%d%H%M%S)-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${REGION}.amazonaws.com"
  backend_image="${registry}/${PROJECT_NAME}-backend:${tag}"
  frontend_image="${registry}/${PROJECT_NAME}-frontend:${tag}"

  log "Logging in to ECR (${registry})"
  aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${registry}"

  # EKS nodes are x86_64; build for that even on ARM machines.
  log "Building and tagging images (${tag})"
  docker build --platform linux/amd64 -t "${backend_image}" "${REPO_ROOT}/application/backend"
  docker build --platform linux/amd64 -t "${frontend_image}" "${REPO_ROOT}/application/frontend"

  log "Pushing images to ECR"
  docker push "${backend_image}"
  docker push "${frontend_image}"

  log "Updating the image names in kubernetes/backend.yaml and kubernetes/frontend.yaml"
  sed -i -E "s|image: [^[:space:]]*${PROJECT_NAME}-backend[^[:space:]]*|image: ${backend_image}|" "${K8S_DIR}/backend.yaml"
  sed -i -E "s|image: [^[:space:]]*${PROJECT_NAME}-frontend[^[:space:]]*|image: ${frontend_image}|" "${K8S_DIR}/frontend.yaml"
  grep -H 'image:' "${K8S_DIR}/backend.yaml" "${K8S_DIR}/frontend.yaml"

  # The namespace must exist before the other files, and kubectl applies a folder in file-name order.
  log "Applying the kubernetes folder"
  kubectl apply -f "${K8S_DIR}/namespace.yaml"
  kubectl apply -f "${K8S_DIR}"

  log "Waiting for the rollouts"
  kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout=300s
  kubectl get pods -n "${NAMESPACE}"
}

do_destroy() {
  log "Deleting the kubernetes folder"
  kubectl delete -f "${K8S_DIR}" --ignore-not-found --wait=true --timeout=600s
  log "Done"
}

preflight

choice="${1:-}"
if [[ -z "${choice}" ]]; then
  cat <<EOF
What do you want to do?
  1) Deploy  - build both images, update the manifests, kubectl apply kubernetes/
  2) Destroy - kubectl delete kubernetes/
EOF
  read -r -p "Enter 1 or 2: " choice
fi

case "${choice}" in
  1) do_deploy ;;
  2) do_destroy ;;
  *) die "Invalid choice '${choice}'. Enter 1 or 2." ;;
esac
