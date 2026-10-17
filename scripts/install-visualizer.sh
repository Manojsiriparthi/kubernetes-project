#!/usr/bin/env bash
# Installs Kubeshark: a web UI that shows live request flow between pods (HTTP and Postgres),
# with source/destination pod names and IPs. Works on EKS, no service mesh needed.
# Usage: scripts/install-visualizer.sh   then open http://localhost:8899
set -euo pipefail
helm repo add kubeshark https://helm.kubeshark.com
helm repo update
helm upgrade --install kubeshark kubeshark/kubeshark -n kubeshark --create-namespace
kubectl -n kubeshark rollout status deploy/kubeshark-hub --timeout=180s
echo "Opening UI on http://localhost:8899 (Ctrl+C to stop). In the UI filter: namespace school-demo"
kubectl -n kubeshark port-forward svc/kubeshark-front 8899:80
