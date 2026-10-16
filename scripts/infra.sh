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
# Destroy helpers: remove what blocks security group deletion (ALBs, leftover ENIs)
# ---------------------------------------------------------------------------
# Deletes the Ingresses/LoadBalancer Services while the ALB controller is still running, so the ALBs and their ENIs go first.
pre_clean_k8s() {
  local cluster="$1" region="$2"
  [[ -n "${cluster}" && -n "${region}" ]] || return 0
  aws eks update-kubeconfig --name "${cluster}" --region "${region}" >/dev/null 2>&1 || return 0
  kubectl get ns >/dev/null 2>&1 || return 0

  log "Deleting Ingresses and LoadBalancer Services first (releases ALB ENIs)"
  kubectl delete ingress --all -A --ignore-not-found --wait=true --timeout=300s || true
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null |
    while read -r ns name; do
      [[ -n "${name}" ]] && kubectl delete svc "${name}" -n "${ns}" --ignore-not-found --wait=true --timeout=300s || true
    done
}

# Deletes ENIs left in "available" state (orphaned VPC CNI/ALB ENIs) that hold the cluster security groups.
delete_orphan_enis() {
  local cluster="$1" region="$2" sgs sg eni
  sgs="$(aws ec2 describe-security-groups --region "${region}" \
    --filters "Name=group-name,Values=${cluster}-cluster*,eks-cluster-sg-${cluster}-*,k8s-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)"
  for sg in ${sgs}; do
    for eni in $(aws ec2 describe-network-interfaces --region "${region}" \
      --filters "Name=group-id,Values=${sg}" "Name=status,Values=available" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true); do
      echo "Deleting orphaned ENI ${eni} (security group ${sg})"
      aws ec2 delete-network-interface --region "${region}" --network-interface-id "${eni}" >/dev/null 2>&1 || true
    done
  done
}

# Waits until EKS has released its control-plane ENIs (they block the cluster security group and the subnets).
wait_for_eks_enis() {
  local cluster="$1" region="$2" count
  [[ -n "${cluster}" && -n "${region}" ]] || return 0
  log "Waiting for EKS control-plane ENIs to be released (up to 30 minutes)"
  for _ in $(seq 1 90); do
    count="$(aws ec2 describe-network-interfaces --region "${region}" \
      --filters "Name=description,Values=Amazon EKS ${cluster}" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
    [[ "${count}" == "0" ]] && { echo "No EKS ENIs left."; return 0; }
    echo "${count} EKS ENI(s) still present..."
    sleep 20
  done
  echo "WARNING: EKS ENIs still present; continuing anyway." >&2
}

# Runs a targeted destroy; on failure waits for AWS to release ENIs, cleans orphans, and retries.
destroy_target() {
  local targets="$1" cluster="$2" region="$3" attempt target
  local args=()
  for target in ${targets}; do args+=("-target=${target}"); done
  for attempt in 1 2 3 4; do
    tf destroy -input=false -auto-approve "${args[@]}" && return 0
    [[ ${attempt} -lt 4 ]] || break
    log "Destroy of ${target} failed (attempt ${attempt}/4); waiting for ENIs, then retrying"
    wait_for_eks_enis "${cluster}" "${region}"
    delete_orphan_enis "${cluster}" "${region}"
  done
  return 1
}

# Removes leftover ENIs and ALB-controller security groups (k8s-*) in the VPC so subnets, SGs and the VPC can be deleted.
clean_vpc_leftovers() {
  local region="$1" vpc eni sg
  vpc="$(tf output -raw vpc_id 2>/dev/null || true)"
  [[ -n "${vpc}" && -n "${region}" ]] || return 0
  for eni in $(aws ec2 describe-network-interfaces --region "${region}" \
    --filters "Name=vpc-id,Values=${vpc}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true); do
    aws ec2 delete-network-interface --region "${region}" --network-interface-id "${eni}" >/dev/null 2>&1 || true
  done
  for sg in $(aws ec2 describe-security-groups --region "${region}" \
    --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=k8s-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --region "${region}" --group-id "${sg}" >/dev/null 2>&1 || true
  done
}

# Order: add-ons -> nodes -> EKS cluster (+ its SG/IAM, after its ENIs are released) -> networking (ENIs, NAT, IGW, subnets, VPC, SGs) -> rest.
destroy_stages() {
  local cluster="$1" region="$2"
  log "1/5 EKS add-ons (Helm releases, ALB controller)"
  destroy_target module.eks_addons "${cluster}" "${region}"
  log "2/5 Node groups"
  destroy_target module.eks_nodes "${cluster}" "${region}"
  log "3/5 EKS cluster only (its security group stays; the control-plane ENIs are released when the cluster is gone)"
  destroy_target module.eks_cluster.module.eks.aws_eks_cluster.this "${cluster}" "${region}"
  log "4/5 Networking: ENIs, NAT gateways, internet gateway, subnets, VPC, security groups (including the EKS cluster SG)"
  wait_for_eks_enis "${cluster}" "${region}"
  clean_vpc_leftovers "${region}"
  destroy_target "module.networking module.eks_cluster" "${cluster}" "${region}"
  log "5/5 Everything that is left"
  tf destroy -input=false -auto-approve
}

# Terraform sometimes leaves these behind (failed or interrupted destroys); they make the next apply fail with "already exists".
# Only called after a successful full destroy, so nothing here is managed by Terraform any more.
cleanup_leftovers() {
  local cluster="$1" region="$2" project="${1%-eks}" key role policy arn attached inline
  [[ -n "${cluster}" && -n "${region}" ]] || return 0
  log "Cleaning leftovers (log group, KMS alias, IAM roles and policies)"

  aws logs delete-log-group --region "${region}" --log-group-name "/aws/eks/${cluster}/cluster" >/dev/null 2>&1 \
    && echo "Deleted log group /aws/eks/${cluster}/cluster" || true

  key="$(aws kms describe-key --region "${region}" --key-id "alias/eks/${cluster}" --query KeyMetadata.KeyId --output text 2>/dev/null || true)"
  if [[ -n "${key}" && "${key}" != "None" ]]; then
    aws kms delete-alias --region "${region}" --alias-name "alias/eks/${cluster}" >/dev/null 2>&1 && echo "Deleted KMS alias alias/eks/${cluster}" || true
    aws kms schedule-key-deletion --region "${region}" --key-id "${key}" --pending-window-in-days 7 >/dev/null 2>&1 || true
  fi

  for role in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '${cluster}-') || starts_with(RoleName, '${project}-')].RoleName" --output text 2>/dev/null || true); do
    for arn in $(aws iam list-attached-role-policies --role-name "${role}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "${role}" --policy-arn "${arn}" >/dev/null 2>&1 || true
    done
    for inline in $(aws iam list-role-policies --role-name "${role}" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "${role}" --policy-name "${inline}" >/dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "${role}" >/dev/null 2>&1 && echo "Deleted IAM role ${role}" || true
  done

  for arn in $(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '${cluster}-')].Arn" --output text 2>/dev/null || true); do
    for attached in $(aws iam list-policy-versions --policy-arn "${arn}" --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null || true); do
      aws iam delete-policy-version --policy-arn "${arn}" --version-id "${attached}" >/dev/null 2>&1 || true
    done
    aws iam delete-policy --policy-arn "${arn}" >/dev/null 2>&1 && echo "Deleted IAM policy ${arn}" || true
  done
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
  pre_clean_k8s "${cluster}" "${region}"

  # While Terraform runs, remove ENIs that would otherwise keep the security group "Still destroying" for many minutes.
  local watcher=""
  if [[ -n "${cluster}" && -n "${region}" ]]; then
    ( while true; do sleep 20; delete_orphan_enis "${cluster}" "${region}"; done ) &
    watcher=$!
  fi

  # Staged destroy: add-ons -> nodes -> EKS cluster -> (wait for its ENIs) -> cluster SG/IAM -> networking (subnets, VPC) -> rest.
  local rc=0
  destroy_stages "${cluster}" "${region}" || rc=$?
  [[ -n "${watcher}" ]] && kill "${watcher}" 2>/dev/null || true
  [[ ${rc} -eq 0 ]] || exit "${rc}"
  cleanup_leftovers "${cluster}" "${region}"

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
