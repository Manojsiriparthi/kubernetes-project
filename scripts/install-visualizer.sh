#!/usr/bin/env bash
# Installs Kubeshark: a web UI that shows live request flow between pods (HTTP and Postgres),
# with source/destination pod names and IPs. Works on EKS, no service mesh needed.
# Usage: scripts/install-visualizer.sh   then open http://<EC2_PUBLIC_IP>:8899
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helm repo add kubeshark https://helm.kubeshark.com
helm repo update
helm upgrade --install kubeshark kubeshark/kubeshark -n kubeshark --create-namespace \
  --values "$SCRIPT_DIR/kubeshark-values.yaml"
kubectl -n kubeshark rollout status deploy/kubeshark-hub --timeout=180s
kubectl -n kubeshark rollout status deploy/kubeshark-front --timeout=180s
pkill -f "port-forward svc/kubeshark-front" 2>/dev/null || true
nohup kubectl -n kubeshark port-forward --address 0.0.0.0 svc/kubeshark-front 8899:80 >/tmp/kubeshark-pf.log 2>&1 &
echo "UI running in background on http://<EC2_PUBLIC_IP>:8899 (open port 8899 in the security group)."
echo "In the UI filter: namespace school-demo. Logs: /tmp/kubeshark-pf.log. Stop: pkill -f 'port-forward svc/kubeshark-front'"
