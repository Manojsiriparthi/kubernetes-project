# 06 - Monitoring and alerts explained

Monitoring answers three questions: **Is it working? How is it doing? Will someone tell me when it breaks?**
This document explains what we watch, how the data is collected, how to see it (Grafana), and how alerts work.

Everything here is installed automatically by Terraform (`modules/eks-addons`) with the Helm chart
**kube-prometheus-stack**. There is nothing to install by hand.

---

## 1. The pieces and what each one does

```
 nodes and pods  --(metrics)-->  PROMETHEUS  --(alert rules)-->  ALERTMANAGER  --> Slack / screen
 (node-exporter,                  stores numbers                   sends the message
  kubelet, kube-state-metrics)        |
                                      +--(data source)-->  GRAFANA  (graphs and dashboards)
```

| Piece | Plain explanation |
|---|---|
| **Metric** | a number measured over time: "CPU used: 0.35", "memory: 1.2 GB" |
| **Prometheus** | the database of metrics. Every 15 seconds it *scrapes* (visits and reads) each target's `/metrics` page |
| **Exporter** | a small program that turns something into a `/metrics` page. **node-exporter** reports each server's CPU, memory, disk, network |
| **kubelet / cAdvisor** | built into every node: reports CPU and memory of every container |
| **kube-state-metrics** | reports Kubernetes facts: how many pods, are they Ready, how often did they restart |
| **Alert rule** | a question Prometheus asks again and again: "is node CPU above 30%?" If yes for long enough, the alert **fires** |
| **Alertmanager** | receives fired alerts, groups them so you do not get 50 messages, and sends them to Slack |
| **Grafana** | draws graphs and dashboards from Prometheus data |
| **metrics-server** | a lighter, separate thing: gives `kubectl top` and the pod autoscaler (HPA) the current CPU/memory |
| **CloudWatch Observability add-on** | AWS's own copy of container metrics and logs, viewable in the AWS console (Container Insights) |

---

## 2. What is being monitored

| What | Where it comes from | Examples you can see |
|---|---|---|
| Servers (nodes) | node-exporter on every node, all three node groups | CPU %, memory %, disk %, network |
| Containers and pods | kubelet cAdvisor | CPU and memory per pod, restarts |
| Kubernetes objects | kube-state-metrics | pods Running/Pending, deployments desired vs available, PVC usage |
| Kubernetes control plane | the chart's scrape of API server, scheduler, etc. | request rates, errors |
| Prometheus itself | self-scrape | is monitoring alive? |
| The Jenkins host (separate) | the Prometheus/Grafana containers from `pre-tools.sh` | basic stack only |

What is **not** monitored yet: request counts and response times of our own backend (the Flask app has no `/metrics`
page). Section 8 shows how to add it.

Prometheus is configured to pick up **every** ServiceMonitor, PodMonitor and rule in **any** namespace
(`serviceMonitorSelectorNilUsesHelmValues=false`), so adding monitoring for a new app needs no change to Prometheus.

---

## 3. How to open the tools

Only IPs listed in `team_access_cidrs` can connect.

```bash
kubectl get ingress -A          # find the ADDRESS of the team tools ALB
```

| Tool | Address | Login |
|---|---|---|
| Grafana | `http://<ALB-ADDRESS>:3000` | `admin` / `terraform -chdir=infra output -raw grafana_admin_password` |
| Prometheus | `http://<ALB-ADDRESS>:9090` | none |
| Alertmanager | `http://<ALB-ADDRESS>:9093` | none |

If you cannot reach the ALB (for example your IP changed), use a tunnel from your laptop:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```
and open `http://localhost:3000` etc.

---

## 4. Grafana: dashboards (what to click)

The chart already includes ready-made dashboards. In Grafana: left menu **Dashboards**.

| Dashboard | What it shows | Use it to |
|---|---|---|
| **Node Exporter / Nodes** | CPU, memory, disk, network per server | is a server overloaded or full? |
| **Kubernetes / Compute Resources / Cluster** | CPU and memory of the whole cluster | overall load |
| **Kubernetes / Compute Resources / Namespace (Pods)** | CPU/memory per pod; choose namespace `school-demo` | which pod uses the most? |
| **Kubernetes / Compute Resources / Pod** | one pod in detail | debugging one pod |
| **Kubernetes / Persistent Volumes** | disk usage of PVCs (the database disk) | is the database disk filling up? |
| **Alertmanager / Overview** | alerts firing | what is wrong now? |

At the top of each dashboard there are drop-down boxes (data source, namespace, pod, time range). Set the time range to
"Last 1 hour" and turn on auto refresh (top right).

### Make your own dashboard (5 minutes)
1. **Dashboards, New, New dashboard, Add visualization**; data source **Prometheus**.
2. In the query box (switch to **Code** mode) paste a query, for example:

   | Panel | Query | Meaning |
   |---|---|---|
   | Pods running in school-demo | `count(kube_pod_status_phase{namespace="school-demo",phase="Running"})` | how many pods are up |
   | Node CPU % | `100 - (avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` | CPU used per node |
   | Node memory % | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` | memory used per node |
   | Backend memory | `sum(container_memory_working_set_bytes{namespace="school-demo",pod=~"backend.*",container="backend"}) by (pod)` | memory per backend pod |
   | Restarts | `sum(kube_pod_container_status_restarts_total{namespace="school-demo"}) by (pod)` | crashes |
   | Database disk % | `kubelet_volume_stats_used_bytes{namespace="school-demo"} / kubelet_volume_stats_capacity_bytes{namespace="school-demo"} * 100` | PVC usage |

3. Choose a visualization (Time series, Stat, Gauge), give the panel a title, press **Apply**.
4. Press **Save dashboard** (top right) and give it a name.

> Data is **not stored on disk**: if the Prometheus or Grafana pod restarts, history and custom dashboards are lost
> (we turned persistence off to keep the learning setup small). Export dashboards as JSON (Share, Export) to keep
> them, or enable persistence later.

---

## 5. Alerts we created

Five rules, defined in `modules/eks-addons/main.tf` (`additionalPrometheusRulesMap`). The thresholds are low on
purpose so you can trigger them while learning.

| Alert | Fires when | For how long | Severity | What it means |
|---|---|---|---|---|
| `NodeHighCPU` | a node uses more than **30%** CPU | 5 min | warning | a server is busy; may need more nodes or pods |
| `NodeHighMemory` | a node uses more than **40%** memory | 5 min | warning | memory pressure; pods may be killed |
| `NodeHighDiskUsage` | the node's root disk is more than **40%** full | 10 min | warning | clean up or enlarge disks |
| `PersistentVolumeHighUsage` | any volume (e.g. the database) is more than **40%** full | 10 min | warning | the database disk will fill up |
| `PodCrashLooping` | a `school-demo` container restarted more than 3 times in 15 minutes | 5 min | critical | an app is crashing repeatedly |

The **"for"** time prevents false alarms: a short spike is ignored; the condition must hold for the whole period.
The first state is *Pending*, then it becomes *Firing*.

The chart also ships many default alert rules (for example "KubePodNotReady", "NodeFilesystemAlmostFull"); they
go to the same Alertmanager.

### Where to see alerts
- Prometheus, menu **Alerts**: every rule with its state (Inactive, Pending, Firing).
- Alertmanager home page: the currently firing alerts.
- Grafana: **Alerting, Alert rules** (Prometheus rules appear there too).

### How the Slack message is sent
Alertmanager reads its settings from Terraform:
- grouped by `alertname` and `namespace`, first message after 30 s, repeat reminders every 4 h;
- if you set `alertmanager_slack_webhook_url` in `terraform.tfvars` and apply, alerts are sent to Slack. If it is
  empty, alerts only show on the Alertmanager page.

To get a webhook: Slack, https://api.slack.com/apps, Create app, **Incoming Webhooks**, add to a channel, copy the URL.

---

## 6. Try it: make an alert fire

Use a short-lived stress pod on an application node (it needs the same toleration as the app):

```bash
kubectl run stress -n school-demo --image=polinux/stress --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"workload":"application"},"tolerations":[{"key":"workload","operator":"Equal","value":"application","effect":"NoSchedule"}]}}' \
  -- stress --cpu 2 --timeout 600
```

Watch in Prometheus (Alerts page) `NodeHighCPU` go Pending, then Firing after 5 minutes; then see it in Alertmanager
and Slack. Clean up: `kubectl delete pod stress -n school-demo`.

To see `PodCrashLooping`: `kubectl exec -n school-demo deploy/backend -- kill 1` a few times (the container restarts).

---

## 7. Related automatic reactions (monitoring that acts by itself)

| Mechanism | Looks at | Does |
|---|---|---|
| HPA (`hpa.yaml`) | pod CPU (from metrics-server) | adds or removes pods |
| Cluster Autoscaler | pods that cannot be scheduled | adds or removes nodes |
| Probes (readiness/liveness) | each container's health | stops traffic or restarts it |
| VPA recommender | pod CPU/memory over time | only **suggests** better requests (`kubectl describe vpa`) |

Monitoring tells people; these tell the cluster.

---

## 8. How to add application metrics (next step)

The backend currently exposes only health pages. To monitor requests per second and latency:
1. Add the library `prometheus-flask-exporter` to `requirements.txt` and enable it in `app.py` (it adds `/metrics`).
2. Add a port named `http` to a `ServiceMonitor` that selects the backend Service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: backend, namespace: school-demo }
spec:
  selector: { matchLabels: { app: backend } }   # the backend Service needs this label
  endpoints: [ { port: http, path: /metrics } ]
```
3. Prometheus finds it automatically (it watches all namespaces). Then chart `flask_http_request_total` and
   `flask_http_request_duration_seconds` in Grafana.

For the database, run the `postgres-exporter` as a second container or separate pod and add a ServiceMonitor the same way.

---

## 9. CloudWatch (AWS's own view)

The `amazon-cloudwatch-observability` add-on sends metrics and container logs to AWS. Open the AWS console,
**CloudWatch, Container Insights** and pick the cluster `school-demo-eks`. EKS control-plane logs (API, audit,
authenticator, scheduler, controller-manager) are in the log group `/aws/eks/school-demo-eks/cluster` for 90 days.
Use CloudWatch for logs and "who did what" (audit log); use Prometheus/Grafana for fast metrics and alerts.

---

## 10. Limits to be aware of

| Limit | Why it matters |
|---|---|
| No persistent storage for Prometheus/Grafana | history and custom dashboards disappear on restart |
| Thresholds 30%/40% are very low | they will fire often on small nodes; raise them for real use |
| Prometheus has no login | protected only by `team_access_cidrs`; consider keeping it internal and using Grafana |
| HTTP, not HTTPS | passwords travel unencrypted until you set `team_certificate_arn` (needs a domain) |
| Pod slots | `t3.medium` nodes hold a limited number of pods; the monitoring stack uses many |
| Chart versions | pinned from memory; confirm with `helm search repo prometheus-community/kube-prometheus-stack --versions` |
