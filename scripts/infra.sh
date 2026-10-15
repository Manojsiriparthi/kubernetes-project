#!/usr/bin/env bash
# One entry point for the whole platform: enter 1 to create everything, 2 to destroy everything.
# Terraform's dependencies enforce the order:
#   apply:   networking -> eks cluster -> node groups -> eks add-ons -> Helm (ALB controller, Argo CD, Prometheus, Grafana)
#   destroy: the reverse, so the ALBs are removed before the cluster and the network.
# Usage: ./scripts/infra.sh [1|2]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra"
TFVARS="${TF_DIR}/terraform.tfvars"
PLAN_FILE="${TF_DIR}/tfplan"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
tf() { terraform -chdir="${TF_DIR}" "$@"; }

# ---------------------------------------------------------------------------
# Checks that run before anything is created or deleted
# ---------------------------------------------------------------------------
preflight() {
  # aws is needed by Terraform's Helm provider (aws eks get-token); kubectl to read the ALB addresses.
  for tool in terraform aws kubectl; do
    command -v "${tool}" >/dev/null || die "'${tool}' is not installed. Run scripts/pre-tools.sh first."
  done

  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are not configured (aws sts get-caller-identity failed)."

  # The two IP allow-lists have no defaults on purpose, so they must be set by you.
  if [[ ! -f "${TFVARS}" ]]; then
    cat >&2 <<EOF
Missing ${TFVARS}. Create it with at least:

  cluster_endpoint_public_access_cidrs = ["<your-ip>/32"]   # who may reach the Kubernetes API (kubectl, Terraform)
  team_access_cidrs                    = ["<your-ip>/32"]   # who may open Argo CD, Prometheus, Alertmanager, Grafana

Find your IP with: curl -s ifconfig.me
EOF
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Option 1: create everything
# ---------------------------------------------------------------------------
do_apply() {
  log "Initialising Terraform"
  tf init -input=false

  log "Formatting"
  tf fmt -recursive

  log "Validating"
  tf validate

  log "Planning"
  tf plan -input=false -out="${PLAN_FILE}"

  read -r -p "Apply this plan? Type 'yes' to continue: " answer
  [[ "${answer}" == "yes" ]] || die "Cancelled."

  log "Applying (EKS and the node groups take a while)"
  if ! tf apply -input=false "${PLAN_FILE}"; then
    cat >&2 <<EOF

Apply failed. If the error says the Helm provider cannot reach the cluster, create the cluster first and re-run:
  terraform -chdir=infra apply -target=module.eks_cluster
  ./scripts/infra.sh 1
EOF
    exit 1
  fi
  rm -f "${PLAN_FILE}"

  show_access_info
}

# Points kubectl at the new cluster and prints the ALB addresses of the team tools.
show_access_info() {
  local cluster region host scheme
  cluster="$(tf output -raw cluster_name)"
  region="$(tf output -raw region)"

  log "Configuring kubectl for ${cluster}"
  aws eks update-kubeconfig --name "${cluster}" --region "${region}" >/dev/null

  # Argo CD, Prometheus, Alertmanager and Grafana share one ALB (Ingress group "team-tools").
  log "Waiting for the team-tools ALB address (up to 10 minutes)"
  host=""
  for _ in $(seq 1 60); do
    host="$(kubectl get ingress -n monitoring -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${host}" ]] && break
    sleep 10
  done
  [[ -n "${host}" ]] || die "The ALB address is not ready yet. Check later with: kubectl get ingress -A"

  scheme="http"
  kubectl get ingress -n monitoring -o jsonpath='{.items[0].metadata.annotations.alb\.ingress\.kubernetes\.io/listen-ports}' \
    2>/dev/null | grep -q HTTPS && scheme="https"

  cat <<EOF

Team tools (only reachable from team_access_cidrs; the ALB can take a few minutes before it answers):
  Argo CD       ${scheme}://${host}:8080
  Grafana       ${scheme}://${host}:3000
  Prometheus    ${scheme}://${host}:9090
  Alertmanager  ${scheme}://${host}:9093

Passwords (run these yourself; they are not printed here):
  Grafana  (user admin):  terraform -chdir=infra output -raw grafana_admin_password
  Argo CD  (user admin):  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

Public app ALB: appears after you deploy the app, with: kubectl get ingress frontend -n school-demo
EOF
}

# ---------------------------------------------------------------------------
# Option 2: destroy everything
# ---------------------------------------------------------------------------
do_destroy() {
  local cluster region
  # Read these first: they are gone once the state is destroyed.
  cluster="$(tf output -raw cluster_name 2>/dev/null || true)"
  region="$(tf output -raw region 2>/dev/null || true)"

  cat <<EOF

This permanently destroys the EKS cluster, node groups, networking, ALBs and ECR repositories.
The app namespace (school-demo) is deleted first so its ALB is cleaned up, which also deletes the database volume.
EOF
  read -r -p "Type 'destroy' to continue: " answer
  [[ "${answer}" == "destroy" ]] || die "Cancelled."

  log "Initialising Terraform"
  tf init -input=false

  # Terraform deletes the app namespace, then Argo CD/monitoring, then the ALB controller, add-ons, nodes, cluster, network.
  log "Destroying in reverse order"
  tf destroy -input=false -auto-approve

  # Safety net: report any ALB the controller created that was not cleaned up (it would keep costing money).
  if [[ -n "${cluster}" && -n "${region}" ]]; then
    log "Checking for leftover load balancers"
    leftovers="$(aws resourcegroupstaggingapi get-resources --region "${region}" \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${cluster}" \
      --resource-type-filters elasticloadbalancing:loadbalancer \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"
    if [[ -n "${leftovers}" ]]; then
      echo "WARNING: these load balancers still exist; delete them in the console or with the AWS CLI:" >&2
      echo "${leftovers}" >&2
    else
      echo "None found."
    fi
  fi

  log "Destroy finished"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
preflight

choice="${1:-}"
if [[ -z "${choice}" ]]; then
  cat <<EOF
What do you want to do?
  1) Apply   - create everything (network, EKS, nodes, add-ons, ALB, Argo CD, Prometheus, Grafana)
  2) Destroy - remove everything in the correct order
EOF
  read -r -p "Enter 1 or 2: " choice
fi

case "${choice}" in
  1) do_apply ;;
  2) do_destroy ;;
  *) die "Invalid choice '${choice}'. Enter 1 or 2." ;;
esac
