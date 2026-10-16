#!/usr/bin/env bash
# Local deploy of the school-demo app: no ECR push.
#   1) Deploy : build both images, set their names in kubernetes/backend.yaml and frontend.yaml, kubectl apply kubernetes/
#   2) Destroy: kubectl delete kubernetes/ (the namespace goes too)
# The cluster must be able to see the local images: kind and minikube are handled below; an EKS cluster cannot pull them.
# Usage: ./scripts/app.sh [1|2]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${REPO_ROOT}/kubernetes"
PROJECT_NAME="${PROJECT_NAME:-school-demo}"
NAMESPACE="school-demo"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

preflight() {
  for tool in docker kubectl git; do
    command -v "${tool}" >/dev/null || die "'${tool}' is not installed."
  done
  kubectl version >/dev/null 2>&1 || die "kubectl cannot reach a cluster."
}

do_deploy() {
  local tag backend_image frontend_image context
  # A new tag per run makes Kubernetes roll out the new image.
  tag="$(date +%Y%m%d%H%M%S)-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  backend_image="${PROJECT_NAME}-backend:${tag}"
  frontend_image="${PROJECT_NAME}-frontend:${tag}"

  log "Building images"
  docker build -t "${backend_image}" "${REPO_ROOT}/application/backend"
  docker build -t "${frontend_image}" "${REPO_ROOT}/application/frontend"

  # Local clusters run their own container runtime, so the images must be loaded into them.
  context="$(kubectl config current-context)"
  case "${context}" in
    kind-*)
      log "Loading images into kind"
      kind load docker-image "${backend_image}" "${frontend_image}" --name "${context#kind-}"
      ;;
    minikube)
      log "Loading images into minikube"
      minikube image load "${backend_image}"
      minikube image load "${frontend_image}"
      ;;
  esac

  log "Updating the image names in kubernetes/backend.yaml and kubernetes/frontend.yaml"
  sed -i -E "s|image: [^[:space:]]*${PROJECT_NAME}-backend[^[:space:]]*|image: ${backend_image}|" "${K8S_DIR}/backend.yaml"
  sed -i -E "s|image: [^[:space:]]*${PROJECT_NAME}-frontend[^[:space:]]*|image: ${frontend_image}|" "${K8S_DIR}/frontend.yaml"
  grep -H 'image:' "${K8S_DIR}/backend.yaml" "${K8S_DIR}/frontend.yaml"

  # The namespace must exist before the other files, and kubectl applies a folder in file-name order.
  log "Applying the kubernetes folder"
  kubectl apply -f "${K8S_DIR}/namespace.yaml"
  kubectl apply -f "${K8S_DIR}"

  log "Done"
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
