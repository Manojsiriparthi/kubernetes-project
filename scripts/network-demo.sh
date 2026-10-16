#!/usr/bin/env bash
# Live demo: follow one request  Client -> ALB -> frontend pod -> backend pod -> Postgres pod
# and print the IPs / pod names at every hop.
# Usage: scripts/network-demo.sh [NAMESPACE]   (needs kubectl access to the cluster, curl, dig or getent)
# Output is shown on screen and also saved (without colors) to demo-output/network-flow-<time>.txt
set -uo pipefail
OUT="${OUT:-demo-output/network-flow-$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p "$(dirname "$OUT")"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >"$OUT")) 2>&1

NS="${1:-school-demo}"
FIRST="${FIRST:-Demo}"; LAST="${LAST:-Student}"; CLASS="${CLASS:-5}"

B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
step() { printf '\n%s========== %s ==========%s\n' "$C" "$1" "$N"; }
run()  { printf '%s$ %s%s\n' "$Y" "$*" "$N"; "$@"; }

step "0. Pods, their IPs and the node they run on (pod IPs are real VPC IPs on EKS)"
run kubectl -n "$NS" get pods -o wide

step "1. Services = stable virtual IPs (ClusterIP) in front of changing pod IPs"
run kubectl -n "$NS" get svc -o wide
echo "${B}Endpoints behind each service (the real pod IPs):${N}"
run kubectl -n "$NS" get endpoints frontend backend postgres

step "2. Ingress -> ALB (created by AWS Load Balancer Controller)"
run kubectl -n "$NS" get ingress frontend
ALB=$(kubectl -n "$NS" get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS name : ${G}${ALB}${N}"
echo "ALB public IPs (DNS answers, one per AZ):"
(dig +short "$ALB" 2>/dev/null || getent hosts "$ALB" | awk '{print $1}') | sed 's/^/   /'
echo "${B}target-type=ip => ALB targets are the frontend POD IPs directly:${N}"
kubectl -n "$NS" get pods -l app=frontend -o custom-columns=POD:.metadata.name,POD_IP:.status.podIP,NODE:.spec.nodeName
if command -v aws >/dev/null; then
  TG=$(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'k8s-schooldemo-frontend')].TargetGroupArn | [0]" --output text 2>/dev/null)
  [ -n "$TG" ] && [ "$TG" != None ] && aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,Health:TargetHealth.State}' --output table
fi

step "3. Fire a real request through the ALB (watch the logs of every tier)"
MARK="demo-$(date +%s)"
LOGDIR=$(mktemp -d); PIDS=()
for app in frontend backend; do
  kubectl -n "$NS" logs -l app=$app --prefix --since=1s --tail=0 -f >"$LOGDIR/$app.log" 2>&1 &
  PIDS+=($!)
done
sleep 3

URL="http://${ALB}/api/students?first_name=${FIRST}&last_name=${LAST}&class_name=${CLASS}"
echo "${Y}\$ curl -sv '$URL' -H 'X-Demo-Id: $MARK'${N}"
curl -sv -H "X-Demo-Id: $MARK" "$URL" 2>&1 | grep -E '^(\*   Trying|< HTTP|< Server|\{|\[)|students|error' | sed 's/^/   /'
sleep 3
kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null

echo; echo "${B}FRONTEND (nginx) saw  -> client/ALB IP is the first field; pod name is the prefix:${N}"
cat "$LOGDIR/frontend.log"
echo; echo "${B}BACKEND (flask) saw   -> source IP should be a FRONTEND pod IP:${N}"
cat "$LOGDIR/backend.log"
rm -rf "$LOGDIR"

step "4. Backend -> Postgres: who is connected to the DB right now (client_addr = backend pod IP)"
PG=$(kubectl -n "$NS" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
DBU=$(kubectl -n "$NS" get cm school-config -o jsonpath='{.data.POSTGRES_USER}')
DBN=$(kubectl -n "$NS" get cm school-config -o jsonpath='{.data.POSTGRES_DB}')
echo "Postgres pod: $PG  IP: $(kubectl -n "$NS" get pod "$PG" -o jsonpath='{.status.podIP}')"
kubectl -n "$NS" exec "$PG" -- psql -U "$DBU" -d "$DBN" -c \
  "select client_addr as client_ip, usename, datname, state, left(query,60) as last_query from pg_stat_activity where client_addr is not null;"
echo "${B}Backend pod IPs for comparison:${N}"
kubectl -n "$NS" get pods -l app=backend -o custom-columns=POD:.metadata.name,POD_IP:.status.podIP

step "5. DNS inside the cluster: how 'backend' and 'postgres' names resolve"
FE=$(kubectl -n "$NS" get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
run kubectl -n "$NS" exec "$FE" -- getent hosts backend
run kubectl -n "$NS" exec "$FE" -- cat /etc/resolv.conf

step "6. Load balancing proof: 10 requests, count which frontend/backend pod served each"
for i in $(seq 10); do curl -s -o /dev/null "http://${ALB}/api/health/ready"; done
echo "Backend pods hit (requests per pod):"
for p in $(kubectl -n "$NS" get pods -l app=backend -o name); do
  printf '  %s : %s\n' "$p" "$(kubectl -n "$NS" logs "$p" --since=2m | grep -c 'health/ready')"
done
step "7. FLOW SUMMARY (this exact run)"
FEIP=$(kubectl -n "$NS" get pods -l app=frontend -o jsonpath='{range .items[*]}{.metadata.name}={.status.podIP} {end}')
BEIP=$(kubectl -n "$NS" get pods -l app=backend -o jsonpath='{range .items[*]}{.metadata.name}={.status.podIP} {end}')
cat <<TXT
 [1] Client  --HTTP GET /api/students?...-->  ALB ($ALB)
 [2] ALB     --forwards to frontend pod IP (target-type=ip)-->  $FEIP
 [3] nginx in frontend pod  --proxy_pass http://backend:5000-->  Service backend ClusterIP $(kubectl -n "$NS" get svc backend -o jsonpath='{.spec.clusterIP}')
 [4] kube-proxy picks one backend pod  -->  $BEIP
 [5] Flask backend  --SQL over TCP 5432 to postgres:5432-->  Service postgres ClusterIP $(kubectl -n "$NS" get svc postgres -o jsonpath='{.spec.clusterIP}') -> pod $PG
 [6] Postgres returns student rows -> backend (JSON) -> nginx -> ALB -> client
TXT
echo "Saved to: $OUT"
echo; echo "${G}Done.${N} Path: client -> ALB -> frontend pod IP -> backend Service -> backend pod IP -> postgres Service -> postgres pod"
