# 04 - Kubernetes files explained, line by line

All the files are in the `kubernetes/` folder. This is what Argo CD deploys. For each file you get:
**what it is, what each important line means, why we need it, what problem it solves.**

If you are new to Kubernetes, first read the five-minute vocabulary below.

---

## 0. Vocabulary

| Word | Plain meaning |
|---|---|
| **Cluster** | all the servers (nodes) working together |
| **Node** | one server |
| **Pod** | the smallest unit: one or more containers that run together on one node. Pods are disposable |
| **Deployment** | "keep N copies of this pod running; update them gently". Used for stateless apps (frontend, backend) |
| **StatefulSet** | like a Deployment, but each pod keeps its own name and its own disk. Used for databases |
| **Service** | a stable address and name in front of pods. Pods come and go; the Service name stays |
| **Ingress** | a rule that says "traffic from the internet to this address goes to that Service" |
| **ConfigMap** | settings (plain text) stored in the cluster |
| **Secret** | settings that are private (passwords) |
| **PVC / PV** | a request for a disk (PVC) and the real disk (PV) |
| **StorageClass** | the type of disk to create and how |
| **Namespace** | a folder inside the cluster that groups things |
| **Label** | a sticker on an object, used to find and group objects |
| **Probe** | a health check Kubernetes runs against a container |

Every file has the same shape:

```yaml
apiVersion: ...   # which version of the Kubernetes language
kind: ...         # what kind of thing this is (Deployment, Service, ...)
metadata:         # its name, namespace, labels
  name: ...
spec:             # what you want
```

You write the **desired state** ("I want 3 backend pods"). Kubernetes keeps making reality match it.

The files, in the order they should be understood:

| File | Kind(s) | One-line job |
|---|---|---|
| `namespace.yaml` | Namespace | the folder everything lives in |
| `storageclass.yaml` | StorageClass | how to create database disks |
| `configmap.yaml` | ConfigMap | database name and user |
| `secret.yaml` | Secret | database password |
| `postgres-init.yaml` | ConfigMap | SQL that creates the tables |
| `postgres.yaml` | 2 Services + StatefulSet | the database |
| `backend.yaml` | Service + Deployment | the API |
| `frontend.yaml` | Service + Deployment | the web server |
| `ingress.yaml` | Ingress | the public address (ALB) |
| `hpa.yaml` | 2 HorizontalPodAutoscalers | add/remove pods with load |
| `pdb.yaml` | 2 PodDisruptionBudgets | never take too many pods down at once |
| `rbac.yaml` | ServiceAccount, Role, RoleBinding | an example read-only identity |

---

## 1. `namespace.yaml`

```yaml
kind: Namespace
metadata:
  name: school-demo                                   # the folder name
  labels:
    app.kubernetes.io/part-of: school-demo            # a label for humans/tools
    elbv2.k8s.aws/pod-readiness-gate-inject: enabled  # see below
```

- **Why a namespace:** all our objects are grouped; `kubectl delete namespace school-demo` removes the whole app.
- **The readiness-gate label** is the key to **zero downtime**. The load balancer controller adds an extra
  condition to every pod here: a new pod only counts as *Ready* when the AWS load balancer says it is healthy.
  *Problem solved:* during an update, old pods are not removed until the new pods really receive traffic from the ALB.

---

## 2. `storageclass.yaml`

```yaml
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com        # who creates the disk: the EBS CSI driver add-on
reclaimPolicy: Delete               # delete the AWS disk when the claim is deleted
volumeBindingMode: WaitForFirstConsumer   # create the disk only when a pod needs it, in that pod's zone
allowVolumeExpansion: true          # the disk can be made bigger later
parameters:
  type: gp3                         # AWS disk type
  encrypted: "true"                 # encrypted disk
```

- **Why:** a StorageClass is a recipe for disks. Pods ask for "10 GiB of gp3" and the cluster builds it.
- **`WaitForFirstConsumer` solves a real problem:** an EBS disk lives in one zone. If the disk were created before
  the pod is placed, the pod might be scheduled in another zone and could never use it. Waiting guarantees the
  disk is created in the same zone as the pod.
- **`reclaimPolicy: Delete`:** a full destroy leaves no orphan disks (and no surprise bill). For real production data
  you would use `Retain`.

---

## 3. `configmap.yaml`

```yaml
kind: ConfigMap
metadata: { name: school-config, namespace: school-demo }
data:
  POSTGRES_DB: school        # database name
  POSTGRES_USER: school_app  # database user
```

- **Why:** settings that are not secret live here, in one place, used by both the backend and the database.
  *Problem solved:* no value is copied in two files, so they cannot disagree.

## 4. `secret.yaml`

```yaml
kind: Secret
metadata: { name: school-db, namespace: school-demo }
type: Opaque
stringData:
  POSTGRES_PASSWORD: change-me-demo-password
```

- **Why:** the password is separate from normal settings, so it can have stricter access, and (with encryption turned
  on in the cluster) is stored encrypted.
- **Warning:** this file holds a placeholder password *in git*, which is acceptable only for learning. For real use,
  keep the password in AWS Secrets Manager and let the secrets-store driver (installed by Terraform) copy it into the
  cluster. Choose a password with only letters and numbers: it is placed inside the database address.

## 5. `postgres-init.yaml`

A ConfigMap that contains one file, `10-school-schema.sql`: it creates the sequence `hall_ticket_seq`, the table
`students` and inserts four demo students.

- **Why:** the official PostgreSQL image runs every `.sql` file found in `/docker-entrypoint-initdb.d/` on its first
  start. We mount this ConfigMap there (see the StatefulSet), so **the tables are created automatically**.
- **Important:** it runs only when the data disk is empty. Changing it later does not change an existing database.

---

## 6. `postgres.yaml` - the database

It contains three objects.

### 6.1 Service `postgres`
```yaml
spec:
  type: ClusterIP            # reachable only inside the cluster
  selector: { app: postgres }  # send traffic to pods that have this label
  ports: [ { name: postgres, port: 5432, targetPort: 5432 } ]
```
The backend connects to the name `postgres` (port 5432). *Problem solved:* the database pod may be replaced and get
a new IP; the name never changes.

### 6.2 Service `postgres-headless`
`clusterIP: None` = no virtual IP; DNS returns the pod directly (`postgres-0.postgres-headless`). A StatefulSet needs
one so each of its pods has its own stable name.

### 6.3 StatefulSet `postgres`
| Lines | Meaning |
|---|---|
| `serviceName: postgres-headless`, `replicas: 1` | one database pod named `postgres-0` (a replicated database is a bigger topic) |
| `automountServiceAccountToken: false` | do not give the pod a Kubernetes API password; the database does not need one (less to steal) |
| `nodeSelector: workload: database` + `tolerations` | run only on the database node, which is tainted for exactly this pod (doc 02) |
| `securityContext: fsGroup: 70, fsGroupChangePolicy: OnRootMismatch` | the disk's files belong to group 70 (the postgres user in this image) so it can write; the change is only applied when needed (fast start) |
| `image: postgres:16-alpine` | the official small PostgreSQL image |
| `env POSTGRES_DB / POSTGRES_USER` from ConfigMap, `POSTGRES_PASSWORD` from Secret | the image creates this database and user on first start |
| `PGDATA: /var/lib/postgresql/data/pgdata` | store data in a sub-folder (a new EBS disk has a `lost+found` folder that PostgreSQL refuses to start in) |
| `resources.requests` (250m CPU, 512Mi) | "reserve at least this much": the scheduler uses it to find a node with room |
| `resources.limits` (1 CPU, 1Gi) | "never use more than this": protects the node from a runaway pod |
| `startupProbe` | runs `pg_isready` every 5s for up to 150s: gives the database time to start; other probes wait for it |
| `readinessProbe` | if it fails, the pod is taken out of the Service (no traffic) |
| `livenessProbe` | if it keeps failing (6 times), Kubernetes restarts the container |
| `volumeMounts` | disk at `/var/lib/postgresql/data`; init SQL (read-only) at `/docker-entrypoint-initdb.d` |
| `volumes: init-sql -> configMap postgres-init` | where the SQL file comes from |
| `volumeClaimTemplates: postgres-data, 10Gi, gp3, ReadWriteOnce` | for each pod create a PVC `postgres-data-postgres-0`; the StorageClass then creates the real PV (an EBS disk) automatically. `ReadWriteOnce` = one node at a time |

**Why a StatefulSet (and not a Deployment)?** A database must keep the *same disk* and the *same name* when its pod is
restarted or moved. A Deployment gives pods random names and shared templates; a StatefulSet gives `postgres-0` and
re-attaches `postgres-data-postgres-0` every time.

**PV and PVC in one sentence:** you never write a PV. You write a *claim* (PVC, "I need 10 GiB gp3"); the
StorageClass creates the *volume* (PV, the EBS disk) and binds them.

---

## 7. `backend.yaml` - the API

### Service `backend`
```yaml
type: ClusterIP
selector: { app: backend }
ports: [ { name: http, port: 5000, targetPort: http } ]
```
The frontend's nginx calls `http://backend:5000`. `targetPort: http` points at the container port *named* `http`.

### Deployment `backend`
| Lines | Meaning / problem solved |
|---|---|
| `replicas: 3` | three copies, one per availability zone: survives the loss of a zone |
| `strategy.rollingUpdate: maxSurge 1, maxUnavailable 0` | during an update start one **extra** new pod first and never remove an old pod until the new one is ready. **No downtime** |
| `selector.matchLabels: app: backend` and `template.labels` | the Deployment owns pods with this label |
| `nodeSelector workload: application` + toleration | run on the application nodes (tainted for this) |
| `topologySpreadConstraints` (zone, `DoNotSchedule`, maxSkew 1) | spread pods evenly over zones. maxSkew 1 means "at most 1 more pod in one zone than in another". With 4 pods the layout 2/1/1 is allowed, so the 4th pod does **not** stay Pending. `matchLabelKeys: [pod-template-hash]` makes this count only pods of the same release |
| `topologySpreadConstraints` (hostname, `ScheduleAnyway`) | also try to spread over nodes, but it is only a preference |
| `securityContext: runAsNonRoot, runAsUser 10001, seccompProfile RuntimeDefault` | the container may not run as root and uses the default system-call filter. Limits the damage if the app is hacked |
| `image: <account>.dkr.ecr...amazonaws.com/school-demo-backend:<tag>` | the image in ECR. The pipeline changes the tag for each release |
| `ports: containerPort 5000, name http` | the port the app listens on |
| `env` POSTGRES_DB/USER (ConfigMap), POSTGRES_PASSWORD (Secret) | values taken from the cluster |
| `env DATABASE_URL: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)` | Kubernetes fills the `$(...)` parts from the variables defined above it. The address `postgres` is the Service name |
| `resources` (100m/128Mi request, 500m/256Mi limit) | reserve a little, cap it |
| `lifecycle.preStop: sleep 10` | when a pod is told to stop, wait 10 s before shutting down, so the load balancer finishes moving traffic away. No requests are lost |
| `startupProbe` `/api/health/ready` (5 s, 30 tries) | gives the app 150 s to start and reach the database |
| `readinessProbe` `/api/health/ready` | no traffic until the database works |
| `livenessProbe` `/api/health/live` | restart if the program hangs |
| `terminationGracePeriodSeconds: 30` | max time allowed to shut down |

---

## 8. `frontend.yaml` - the web server

Same structure as the backend. Differences:
- Service `frontend`: port 80, to container port `http` (8080). It is a `ClusterIP` Service: **it is not public by
  itself**; the Ingress in the next section makes it public.
- `runAsUser: 101` (the `nginx` user).
- Probes call `/` (the home page).
- No environment variables: nginx only needs to know that `backend` is a name (DNS).

---

## 9. `ingress.yaml` - the public address

```yaml
kind: Ingress
metadata:
  name: frontend
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing          # a public load balancer
    alb.ingress.kubernetes.io/target-type: ip                  # send traffic straight to pod IPs
    alb.ingress.kubernetes.io/group.name: public-frontend      # name of this ALB group
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'   # accept HTTP on port 80
    alb.ingress.kubernetes.io/healthcheck-path: /              # the ALB checks this address
spec:
  ingressClassName: alb                                         # handled by the AWS load balancer controller
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: frontend, port: { name: http } } }   # send to Service frontend
```

- **What happens:** the load balancer controller sees this object and *creates a real AWS Application Load Balancer*
  in the public subnets, with a target group that contains the frontend pods' IPs.
- **Why `target-type: ip`:** traffic goes ALB to pod directly, with one fewer hop, and works with the readiness gate.
- **Open to everyone** on purpose: this is the customer-facing website. (The team tools ALB is separate and
  restricted by IP.)
- It is HTTP only. For HTTPS you need a domain name and an ACM certificate.

---

## 10. `hpa.yaml` - automatic scaling of pods

```yaml
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef: { kind: Deployment, name: frontend }   # which Deployment to scale
  minReplicas: 3        # never fewer than 3 (one per zone)
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
```
- **Meaning:** if the average CPU of the pods goes above 70% of what they requested, add pods (up to 6); when it
  drops, remove them (down to 3).
- **Needs:** metrics-server (installed by Terraform) to read CPU.
- **Problem solved:** a traffic spike is handled without you doing anything, and you do not pay for idle pods.
- Two of them: one for the frontend, one for the backend.
- If new pods do not fit on the nodes, the **Cluster Autoscaler** adds a node. (Pods scale with the HPA; nodes scale
  with the Cluster Autoscaler.)

## 11. `pdb.yaml` - protection during maintenance

```yaml
kind: PodDisruptionBudget
spec:
  minAvailable: 2
  selector: { matchLabels: { app: frontend } }
```
- **Meaning:** whenever someone *voluntarily* removes pods (draining a node for an upgrade, the autoscaler shrinking
  the cluster), at least 2 frontend pods must stay running.
- **Problem solved:** a node upgrade can never take the whole website down. (It does not protect against a crash.)

## 12. `rbac.yaml` - an example of permissions inside the cluster

| Object | Meaning |
|---|---|
| ServiceAccount `school-observer` | an identity for a program (`automountServiceAccountToken: false`: it gets no token unless asked) |
| Role `school-observer` | what is allowed, in this namespace only: `get`, `list`, `watch` on pods, services, PVCs, deployments, statefulsets, replicasets. Read only |
| RoleBinding `school-observer` | connects the Role to the ServiceAccount |

- **RBAC** = Role-Based Access Control: *who* (subject) may do *what* (verbs) on *which things* (resources).
- It is a teaching example of the principle of **least privilege**: give only what is needed.
- Do not confuse it with the **AWS-level** access (EKS access entries, doc 02), which decides which *people* can use
  `kubectl` at all.

---

## 13. How the files work together

```
Internet
   |
 [ALB]  <--- Ingress "frontend" creates it
   |  (port 80, straight to pod IPs)
 frontend pods (3, on application nodes, spread over 3 zones)    <--- Service "frontend", HPA, PDB
   |  nginx forwards /api/ to  http://backend:5000
 backend pods (3, on application nodes)                           <--- Service "backend", HPA, PDB
   |  postgresql://...@postgres:5432/school
 postgres-0 (1 pod, on the database node)                         <--- Service "postgres", StatefulSet
   |
 EBS disk 10 GiB (PVC postgres-data-postgres-0, StorageClass gp3)
```

Settings come from: ConfigMap `school-config` (names), Secret `school-db` (password), ConfigMap `postgres-init` (tables).

---

## 14. Commands you should learn

Always add `-n school-demo` (the namespace), or set it once:
`kubectl config set-context --current --namespace=school-demo`.

### See things
| Command | Shows |
|---|---|
| `kubectl get pods -o wide` | pods, their status, node and IP |
| `kubectl get svc` | services and their cluster IPs |
| `kubectl get ingress` | the public ALB address in the ADDRESS column |
| `kubectl get pvc` / `kubectl get pv` | the claimed disk and the real disk |
| `kubectl get deploy,sts,hpa,pdb` | the workload objects |
| `kubectl get events --sort-by=.lastTimestamp` | what the cluster did recently (great for "why is it broken?") |
| `kubectl get nodes -L workload` | nodes and their `workload` label |

How to read the STATUS column of `get pods`:

| Status | Meaning | Typical cause |
|---|---|---|
| `Running` + `1/1` READY | healthy | |
| `Pending` | no node accepted it | not enough CPU/memory, missing toleration, disk in another zone. Run `describe` |
| `ContainerCreating` | starting | pulling the image, waiting for a disk or the ConfigMap/Secret |
| `ImagePullBackOff` | cannot download the image | wrong tag or the image is not in ECR |
| `CrashLoopBackOff` | starts and dies again and again | app error: read `logs` |
| `CreateContainerConfigError` | a ConfigMap/Secret it needs is missing | create it |
| `Running` but `0/1` READY | readiness probe failing | the app is up but cannot serve (e.g. no database) |

### Describe: the details and the story of one object
```bash
kubectl describe pod <pod-name>
kubectl describe pod -l app=backend          # all backend pods
```
Read these parts: **Node** (where it runs), **Containers > State / Last State / Restart Count** (did it crash?),
**Conditions** (Ready? ContainersReady?), and above all **Events** at the bottom: it says in words why a pod is
Pending or failing ("0/5 nodes are available: ... didn't match Pod's node affinity/selector", "Failed to pull image").

### Logs: what the program printed
```bash
kubectl logs deployment/backend --tail=50        # last 50 lines
kubectl logs deployment/backend -f               # follow live (Ctrl+C to stop)
kubectl logs <pod-name> --previous               # logs of the crashed previous container
kubectl logs -l app=frontend --all-containers    # all frontend pods
```

### Networking: "can A reach B?"
```bash
kubectl get endpoints                            # which pod IPs are behind each Service (empty = no ready pods)
kubectl exec deploy/frontend -- wget -qO- http://backend:5000/api/health/ready   # frontend -> backend by name
kubectl exec deploy/backend -- python -c "import socket;print(socket.gethostbyname('postgres'))"   # DNS lookup
kubectl port-forward svc/frontend 8081:80        # open http://localhost:8081 to test one Service (Ctrl+C to stop)
```
How to think: *browser -> ALB -> pod IP* (Ingress), *pod -> Service name -> DNS (coredns) -> pod IP* (kube-proxy
rules). If a Service has no endpoints, its pods are not Ready or the selector labels do not match.

### Change and fix
| Command | Does |
|---|---|
| `kubectl rollout status deployment/frontend` | watch an update |
| `kubectl rollout history deployment/frontend` | list previous versions |
| `kubectl rollout restart deployment/backend` | restart pods one by one |
| `kubectl scale deployment/backend --replicas=4` | temporary scale (HPA/Argo CD may change it back) |
| `kubectl exec -it postgres-0 -- sh` | a shell inside a pod |
| `kubectl top pods` / `kubectl top nodes` | CPU and memory now (needs metrics-server) |
| `kubectl delete pod <name>` | kill one pod; the Deployment creates a new one (self-healing demo) |

### A debugging routine that works for almost everything
1. `kubectl get pods` - what is the status?
2. `kubectl describe pod <name>` - read **Events**.
3. `kubectl logs <name>` (and `--previous`) - read the error.
4. `kubectl get events --sort-by=.lastTimestamp` - anything about the node, disk or image?
5. `kubectl get endpoints` and `kubectl exec ... wget` - is it a network problem?
