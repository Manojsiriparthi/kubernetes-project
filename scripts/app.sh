#!/usr/bin/env bash
# Deploys or removes the student app on the EKS cluster created by scripts/infra.sh.
#   1) Deploy : log in to ECR -> build + push frontend and backend images -> write the new image names into
#               kubernetes/frontend.yaml and kubernetes/backend.yaml -> kubectl apply -> show all ingresses.
#   2) Destroy: delete the app from the cluster (and its ALB), then delete every image in the ECR repositories.
# Usage: ./scripts/app.sh [1|2]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra"
K8S_DIR="${REPO_ROOT}/kubernetes"
# The namespace and StorageClass names come from the manifests of the branch you have checked out
# (school-demo-v1 / gp3-v1 on release/version1, school-demo-v2 / gp3-v2 on release/version2).
NAMESPACE="$(awk '/^  name:/ {print $2; exit}' "${K8S_DIR}/namespace.yaml")"
STORAGE_CLASS="$(awk '/^  name:/ {print $2; exit}' "${K8S_DIR}/storageclass.yaml")"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
tf_out() { terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Checks, and values read from the Terraform outputs (so the infra must already be applied)
# ---------------------------------------------------------------------------
preflight() {
  for tool in terraform aws kubectl docker; do
    command -v "${tool}" >/dev/null || die "'${tool}' is not installed. Run scripts/pre-tools.sh first."
  done
  docker info >/dev/null 2>&1 || die "Docker is not running (or your user cannot use it)."
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are not configured."

  REGION="$(tf_out region)" || die "No Terraform outputs found. Create the infrastructure first: ./scripts/infra.sh 1"
  CLUSTER="$(tf_out cluster_name)"
  FRONTEND_REPO="$(tf_out frontend_ecr_repository_url)"
  BACKEND_REPO="$(tf_out backend_ecr_repository_url)"
  REGISTRY="${FRONTEND_REPO%%/*}"

  # Point kubectl at the cluster.
  aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
}

# ---------------------------------------------------------------------------
# Option 1: build, push, update manifests, deploy
# ---------------------------------------------------------------------------
# Builds one image, pushes it, and writes the new image name into its Deployment manifest.
build_push_update() {
  local name="$1" repo="$2" context="$3" manifest="$4"
  log "Building ${name} image"
  # The nodes are x86_64, so build for that even when running on an ARM machine.
  docker build --platform linux/amd64 -t "${repo}:${TAG}" "${context}"

  log "Pushing ${name} image to ECR"
  docker push "${repo}:${TAG}"

  # Replace whatever image the container uses now (local name or an older ECR tag).
  log "Updating ${manifest##*/} to ${repo}:${TAG}"
  sed -i -E "s|image: [^[:space:]]*school-demo-${name}[^[:space:]]*|image: ${repo}:${TAG}|" "${manifest}"
}

do_deploy() {
  # ECR tags are immutable, so every deploy needs a new tag.
  TAG="v$(date +%Y%m%d-%H%M%S)"

  log "Logging in to ECR (${REGISTRY})"
  aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"

  build_push_update frontend "${FRONTEND_REPO}" "${REPO_ROOT}/application/frontend" "${K8S_DIR}/frontend.yaml"
  build_push_update backend "${BACKEND_REPO}" "${REPO_ROOT}/application/backend" "${K8S_DIR}/backend.yaml"

  # Namespace, storage class and the config/secret/init SQL first, so nothing waits on a missing dependency.
  log "Applying namespace, storage class, config and secrets"
  kubectl apply \
    -f "${K8S_DIR}/namespace.yaml" \
    -f "${K8S_DIR}/storageclass.yaml" \
    -f "${K8S_DIR}/configmap.yaml" \
    -f "${K8S_DIR}/secret.yaml" \
    -f "${K8S_DIR}/postgres-init.yaml" \
    -f "${K8S_DIR}/rbac.yaml"

  log "Applying everything in kubernetes/"
  kubectl apply -f "${K8S_DIR}/"

  log "Waiting for the database, backend and frontend"
  kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=10m
  kubectl rollout status deployment/backend -n "${NAMESPACE}" --timeout=10m
  kubectl rollout status deployment/frontend -n "${NAMESPACE}" --timeout=10m

  show_ingresses
}

# Prints every Ingress in the cluster (the public app ALB and the team tools ALB) and the app's URL.
show_ingresses() {
  local host=""
  log "Waiting for the public app ALB address (up to 10 minutes)"
  for _ in $(seq 1 60); do
    host="$(kubectl get ingress frontend -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && break
    sleep 10
  done

  log "All ingresses"
  kubectl get ingress -A -o wide

  if [[ -n "${host}" ]]; then
    printf '\nStudent app: http://%s  (the ALB can take a few minutes before it answers)\n' "${host}"
  else
    echo "The app ALB address is not ready yet; check again with: kubectl get ingress -A"
  fi
}

# ---------------------------------------------------------------------------
# Option 2: remove the app and clean ECR
# ---------------------------------------------------------------------------
# Deletes every image in one ECR repository, 100 at a time (the API limit).
empty_repository() {
  local repo_name="$1" ids
  log "Deleting all images in ECR repository ${repo_name}"
  while true; do
    ids="$(aws ecr list-images --region "${REGION}" --repository-name "${repo_name}" \
      --max-items 100 --query 'imageIds' --output json 2>/dev/null || echo '[]')"
    [[ "${ids}" == "[]" || -z "${ids}" ]] && break
    aws ecr batch-delete-image --region "${REGION}" --repository-name "${repo_name}" --image-ids "${ids}" >/dev/null
  done
}

do_destroy() {
  cat <<EOF

This deletes the whole app from the cluster (namespace ${NAMESPACE}, its ALB and the database volume)
and every image in the frontend and backend ECR repositories.
EOF
  read -r -p "Type 'destroy' to continue: " answer
  [[ "${answer}" == "destroy" ]] || die "Cancelled."

  # Deleting the namespace removes the Ingress first, so the AWS Load Balancer Controller can delete the ALB.
  log "Deleting namespace ${NAMESPACE} (this also removes the public ALB and the database PVC)"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=15m
  kubectl delete storageclass "${STORAGE_CLASS}" --ignore-not-found

  empty_repository "${FRONTEND_REPO##*/}"
  empty_repository "${BACKEND_REPO##*/}"

  log "App removed and ECR images deleted"
  echo "The empty ECR repositories belong to Terraform and are deleted by ./scripts/infra.sh 2."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
preflight

choice="${1:-}"
if [[ -z "${choice}" ]]; then
  cat <<EOF
What do you want to do?
  1) Deploy  - build and push images, update the manifests, kubectl apply, show ingresses
  2) Destroy - delete the app from the cluster and clean the ECR repositories
EOF
  read -r -p "Enter 1 or 2: " choice
fi

case "${choice}" in
  1) do_deploy ;;
  2) do_destroy ;;
  *) die "Invalid choice '${choice}'. Enter 1 or 2." ;;
esac
