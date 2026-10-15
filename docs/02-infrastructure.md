# 02 - Infrastructure explained

This document explains everything Terraform builds in AWS, in plain words. For each part you get three answers:
**What is it? Why do we need it? What problem does it solve?**

All the code is in the `infra/` folder:

```
infra/
  backend.tf        where Terraform stores its memory (S3)
  versions.tf       which Terraform/provider versions to use, how to connect to the cluster
  variables.tf      the settings you can change
  main.tf           connects the building blocks (modules) together
  modules/
    networking/     the private network
    eks-cluster/    the Kubernetes control plane
    eks-nodes/      the servers that run your containers
    eks-addons/     extra software installed into the cluster
```

A **module** is just a folder of Terraform code that builds one piece. `main.tf` calls the modules in order.

---

## 1. The order things are built (and removed)

```
networking  ->  eks_cluster  ->  eks_nodes  ->  eks_addons
 (network)      (brain)          (servers)       (extra software)
```

- On `terraform apply` they are created from left to right. A thing can only be created after the thing it needs.
  (You cannot put servers in a network that does not exist yet.)
- On `terraform destroy` the order is reversed, so nothing is removed while something still depends on it.
- This is enforced in `infra/main.tf` with `depends_on`. That is why **one apply and one destroy are enough**.

---

## 2. `backend.tf` and `versions.tf`

**backend.tf** - "where Terraform keeps its notes".
Terraform must remember what it already created. This file says: keep the notes in an S3 bucket
(`bucket = ...`), file name `key = school-demo/infra/terraform.tfstate`, encrypted (`encrypt = true`), and lock the
notes while someone runs Terraform (`use_lockfile = true`) so two people cannot change things at the same time.
*Problem solved:* without shared notes, a second person (or Jenkins) would create everything again.

**versions.tf** - "which tools to use".
- `required_version = ">= 1.10.0"`: the minimum Terraform version.
- `aws`, `random`, `helm` providers: plug-ins that let Terraform talk to AWS, generate random passwords, and install
  Helm charts.
- The `provider "helm"` block tells Terraform how to log in to the new cluster:
  host = the cluster address, `cluster_ca_certificate` = how to trust it, and
  `exec { command = "aws" args = ["eks","get-token", ...] }` = "ask AWS for a temporary login token". That is why the
  `aws` command must exist on the machine that runs Terraform.

---

## 3. `variables.tf` - the settings

| Variable | Default | Meaning |
|---|---|---|
| `region` | `us-east-1` | which AWS region (data centre area) |
| `project_name` | `school-demo` | name prefix for everything (cluster = `school-demo-eks`) |
| `environment` | `production` | a tag only, for cost reports |
| `vpc_cidr` | `10.0.0.0/16` | the private network address range (65,536 addresses) |
| `availability_zone_count` | `3` | how many data centres (zones) to spread over (3 or 4) |
| `kubernetes_version` | `1.35` | Kubernetes version. **Check this against what EKS offers today** (see "Things to verify") |
| `cluster_endpoint_public_access_cidrs` | none, required | IPs allowed to reach the cluster API |
| `team_access_cidrs` | none, required | IPs allowed to open Argo CD / Grafana / Prometheus |
| `public_node_group` | 1 x `t3.medium` (max 2) | the edge server |
| `application_node_group` | 3 x `t3.medium` (max 6) | servers for frontend and backend |
| `database_node_group` | 1 x `t3.medium` (max 1) | server for the database |
| `node_volume_size_gib` | 80 | disk size of each server, encrypted |
| `cluster_log_retention_days` | 90 | how long cluster logs are kept |
| `*_principal_arns` | empty | extra people who get cluster access (see section 6) |
| `alertmanager_slack_webhook_url` | null | where alerts are sent |
| `team_certificate_arn` | null | certificate for HTTPS on the team tools ALB (needs a domain) |

---

## 4. Networking (`modules/networking`)

### What is it?
A private network inside AWS, called a **VPC**. Think of it as a fenced plot of land where only your things live.

### The layout

```
VPC 10.0.0.0/16
 |-- 3 public subnets    10.0.0.0/20  10.0.16.0/20  10.0.32.0/20     (one per zone)
 |-- 3 private subnets   10.0.64.0/20 10.0.80.0/20  10.0.96.0/20     (one per zone)
 |-- 3 database subnets  10.0.128.0/20 10.0.144.0/20 10.0.160.0/20   (one per zone)
```

The code that makes these: `cidrsubnet(var.vpc_cidr, 4, index)` cuts the big range into /20 pieces
(4,096 addresses each). Public uses pieces 0-2, private 4-6, database 8-10.

### Availability zones (AZ)
An AZ is one physical data centre in a region (for example `us-east-1a`). We use three. **Why:** if one data centre
loses power, the website keeps running from the other two. This is also why the pods are spread over zones
(doc 04).

### The three subnet types
| Subnet | Who lives there | Can the internet reach it? | Why |
|---|---|---|---|
| **public** | the load balancers and the edge server | yes (through the internet gateway) | the only place that must be reachable from outside |
| **private** | the application servers (frontend, backend) | no, they can only go out | protects your app from direct attacks |
| **database** | the database server | no, they can only go out | the most protected place |

### Gateways and route tables
- **Internet gateway (IGW)** - the front door of the VPC. Public subnets route `0.0.0.0/0` (everything) to it.
- **NAT gateway** - a one-way door. Private and database servers can *go out* (download images, talk to AWS) but the
  internet cannot come in. We create **one** (`single_nat_gateway = true`): cheaper, but if its zone fails, private
  servers lose internet. For production use one per zone (`one_nat_gateway_per_az = true`).
- **Route tables** - signposts. They say "traffic to the internet goes to the IGW (public) or to the NAT (private)".
  Database subnets get their own table and are routed to the NAT only (`create_database_internet_gateway_route = false`).

### Other lines in `main.tf` explained
| Line | Meaning | Why |
|---|---|---|
| `enable_dns_hostnames/support = true` | servers get DNS names | Kubernetes needs DNS inside the VPC |
| `map_public_ip_on_launch = false` | no automatic public IPs | only things that must be public get one |
| `manage_default_security_group = true` with no rules | the default firewall allows nothing | stops accidental use of an open default firewall |
| `public_subnet_tags: kubernetes.io/role/elb = 1` | marks subnets for internet-facing load balancers | the load balancer controller finds where to place the ALB |
| `private_subnet_tags: kubernetes.io/role/internal-elb = 1` | marks subnets for internal load balancers | same |
| `kubernetes.io/cluster/school-demo-eks = shared` | "this subnet belongs to the cluster" | Kubernetes discovers its subnets |

### The database security group
A **security group** is a firewall for servers. `aws_security_group.database` plus one rule per private subnet allows
**port 5432 (PostgreSQL) only from the private subnets**. *Problem solved:* nobody from the internet or from other
networks can reach the database port.

---

## 5. EKS cluster (`modules/eks-cluster`)

### What is it?
**EKS** is Amazon's managed Kubernetes. AWS runs the "brain" (control plane: API server, scheduler, database called
etcd) for you. You only run the servers that do the work (nodes).

### Settings explained
| Setting | What it does | Why / problem solved |
|---|---|---|
| `cluster_version` | Kubernetes version | pinned so upgrades are deliberate |
| `iam_role_name = "<cluster>-cluster-role"` | the **IAM role** the control plane uses | an IAM role is "an identity with permissions"; EKS needs one to create network interfaces and load balancers for you |
| `control_plane_subnet_ids` / `subnet_ids` | the private subnets | the control plane's network cards sit in private subnets |
| `cluster_endpoint_private_access = true` | the API is reachable from inside the VPC | nodes talk to it privately |
| `cluster_endpoint_public_access` + `..._cidrs` | the API is also reachable from the internet, but only from your IPs | you can run `kubectl` from your laptop without letting the world in |
| `authentication_mode = "API"` | people get access through **EKS access entries** | the old method (`aws-auth` ConfigMap) is error-prone; one wrong edit locked people out |
| `enable_cluster_creator_admin_permissions = true` | whoever created the cluster is admin | so you can log in after creation |
| `access_entries` | extra admin / developer / viewer people | see below |
| `cluster_enabled_log_types` (5 types) | send API, audit, authenticator, controller-manager, scheduler logs to CloudWatch | to see who did what, and to debug |
| `cloudwatch_log_group_retention_in_days` | keep logs 90 days | logs cost money if kept forever |
| `create_kms_key` + `cluster_encryption_config` | encrypt Kubernetes **Secrets** with our own key, rotated yearly | Secrets are otherwise only base64 text in the database |
| `enable_irsa = true` | creates the **OIDC provider** | lets a pod use an IAM role (see section 7) |
| `create_node_security_group = false` | do not build an extra node firewall | nodes use the cluster firewall EKS creates itself |
| `cluster_upgrade_policy STANDARD` | normal support period | predictable upgrade cost |

### Access levels (RBAC at the AWS level)
Three lists of IAM identities can be set in `terraform.tfvars`:

| List | Gets | Scope |
|---|---|---|
| `cluster_admin_principal_arns` | `AmazonEKSClusterAdminPolicy` (everything) | whole cluster |
| `cluster_developer_principal_arns` | `AmazonEKSEditPolicy` (create/edit workloads) | only namespaces `school-demo`, `school-demo-v1`, `school-demo-v2` |
| `cluster_viewer_principal_arns` | `AmazonEKSViewPolicy` (read only) | whole cluster |

*Problem solved:* people get only the rights they need.

---

## 6. Nodes (`modules/eks-nodes`)

### What is it?
**Nodes** are the servers (EC2 machines) that run your containers. EKS "managed node groups" create, patch and
replace them for you.

### Three node groups

| Group | Subnets | Size | Label | Taint | What runs here |
|---|---|---|---|---|---|
| `public` | public | 1 (max 2) | `workload=public` | none | cluster helpers: CoreDNS, load balancer controller, autoscaler, metrics-server, VPA |
| `application` | private | 3 (max 6) | `workload=application` | `workload=application:NoSchedule` | frontend, backend, Argo CD, Prometheus, Grafana |
| `database` | database | 1 (max 1) | `workload=database` | `workload=database:NoSchedule` | PostgreSQL only |

### Node selector, label and taint (very important idea)
Kubernetes by default puts a pod on any node with free space. We want control:

- **Label** - a sticker on the node: `workload=database`.
- **nodeSelector** - a pod says "I only want nodes with this sticker": `nodeSelector: workload: database`.
- **Taint** - a "keep out" sign on a node: `workload=database:NoSchedule` means "no pod may land here unless it
  tolerates this".
- **Toleration** - the pod's pass: `tolerations: - key: workload value: database effect: NoSchedule`.

Together: the database pod is **pulled** to the database node (nodeSelector) and everyone else is **kept out**
(taint). *Problem solved:* a noisy app can never steal the database's CPU/memory, and the database cannot be
moved by accident. The `public` group has no taint on purpose: CoreDNS and the controllers must be able to run
somewhere, and they do not have tolerations.

### The node IAM role (one per group)
Each server has an IAM role with three AWS-managed policies:

| Policy | Permission | Why the node needs it |
|---|---|---|
| `AmazonEKSWorkerNodePolicy` | talk to the EKS API, describe EC2 | to join the cluster |
| `AmazonEC2ContainerRegistryReadOnly` | pull images from ECR | to download your frontend/backend images |
| `AmazonSSMManagedInstanceCore` | AWS Systems Manager access | log in to a node without SSH keys and open ports |

The network plug-in permission is **not** here; it is given to the plug-in itself (section 7).

### The launch template (how each server is built)
| Setting | Meaning | Why |
|---|---|---|
| `http_tokens = "required"` (IMDSv2) | metadata service needs a token | blocks a common attack (stealing the node's credentials through a vulnerable app) |
| `http_put_response_hop_limit = 1` | only the node itself, not pods, can read metadata | pods cannot steal the node role |
| 80 GiB `gp3`, `encrypted = true` | encrypted root disk | protects data at rest |
| `associate_public_ip_address = (group == public)` | only the edge server has a public IP | everything else stays hidden |

### Autoscaling tags
`k8s.io/cluster-autoscaler/enabled` and `.../school-demo-eks=owned` tags tell the Cluster Autoscaler which groups it may
grow. `desired_size` is ignored after creation (`lifecycle ignore_changes`) so Terraform does not fight the autoscaler.

---

## 7. Add-ons (`modules/eks-addons`)

Add-ons are extra programs installed inside the cluster. They come in two kinds: **EKS-managed add-ons** (installed
by AWS) and **Helm charts** (installed with Helm, which is like an app store for Kubernetes).

### How pods get AWS permissions: IRSA
A pod sometimes needs to call AWS (for example the load balancer controller creates load balancers). Giving the whole
node that power would be dangerous. **IRSA** (IAM Roles for Service Accounts) gives a role to one specific
program only: the role's "trust policy" says "only the service account `aws-load-balancer-controller` in the
`kube-system` namespace, verified by our cluster's OIDC provider, may use me". *Problem solved:* least privilege.

### EKS-managed add-ons
| Add-on | What it is | Why it is required | IAM role |
|---|---|---|---|
| **vpc-cni** | gives every pod its own VPC IP address | pods talk to each other and to AWS like normal machines | `AmazonEKS_CNI_Policy` (IRSA) |
| **kube-proxy** | sets network rules on each node so a Service address reaches the right pod | `Service` addresses would not work | none |
| **coredns** | the cluster's DNS: turns `backend` or `postgres` into an IP | the frontend finds the backend by name | none |
| **aws-ebs-csi-driver** | creates and attaches EBS disks for PersistentVolumes | the database needs a disk that survives restarts | `AmazonEBSCSIDriverPolicy` (IRSA) |
| **amazon-cloudwatch-observability** | sends container metrics and logs to CloudWatch | monitoring and log search in AWS | `CloudWatchAgentServerPolicy` (IRSA) |

They are installed after the nodes exist (coredns and the EBS driver need running servers) and are tracked by a
"gate" resource so the Helm charts only start when all of them are active.

### Helm add-ons
| Chart | What it does | Why / problem solved | Runs on |
|---|---|---|---|
| **aws-load-balancer-controller** | turns an `Ingress` into a real AWS Application Load Balancer | the website needs a public address | public node |
| **cluster-autoscaler** | adds nodes when pods cannot fit, removes empty ones | handles traffic growth automatically | public node |
| **metrics-server** | measures pod CPU/memory | needed by `kubectl top` and the HPA (pod autoscaler) | public node |
| **vpa** (recommender only) | suggests better CPU/memory requests | right-sizing advice, without restarting pods | public node |
| **secrets-store-csi-driver** + **AWS provider** | lets pods read secrets from AWS Secrets Manager | the safe way to handle real passwords (later) | every node (tolerates all taints) |
| **argo-cd** | watches GitHub and deploys to the cluster | the CD half of the pipeline | application nodes |
| **kube-prometheus-stack** | Prometheus, Alertmanager, Grafana, node-exporter | monitoring and alerts (doc 06) | application nodes |

The load balancer controller has its own IAM policy file (`aws-lbc-iam-policy.json`) because it must create
load balancers, target groups and security groups. The autoscaler has a custom policy that may only scale groups
tagged for this cluster.

### Team tools ALB
Argo CD, Prometheus, Alertmanager and Grafana share **one** Application Load Balancer (Ingress group `team-tools`).
Each tool has its own port (8080, 9090, 9093, 3000) because we have no domain name to separate them.
The annotation `inbound-cidrs` becomes the ALB's firewall: **only `team_access_cidrs` can connect**.

### The cleanup resource
`terraform_data.app_cleanup` runs a command only on `terraform destroy`: it deletes the Argo CD applications and every
`school-demo*` namespace first. *Problem solved:* the ALB the app created is not known to Terraform, and a leftover
ALB would block deleting the VPC.

---

## 8. Other resources in `main.tf`

**ECR repositories** (`school-demo-frontend`, `school-demo-backend`): private storage for container images.
- `image_tag_mutability = "IMMUTABLE"`: a pushed tag can never be overwritten, so `42-abc123` always means the same
  image. (Rollback depends on this.)
- `scan_on_push = true`: every image is scanned for known vulnerabilities.
- `force_delete = true`: `terraform destroy` can remove a repository even if it still contains images.

**Outputs** (printed at the end): region, cluster name and endpoint, VPC id, node group names, IAM role ARNs, ECR
repository addresses, the Grafana password (sensitive).

---

## 9. Things to verify before you rely on this

| Item | Why |
|---|---|
| `kubernetes_version = "1.35"` | confirm EKS currently supports it; otherwise change the default in `variables.tf` |
| Helm chart versions in `eks-addons/main.tf` (`argo-cd 8.3.0`, `kube-prometheus-stack 75.15.0`, `secrets-store-csi-driver 1.5.3`, provider-aws `1.0.1`, `vpa 4.7.2`, `metrics-server 3.12.2`) | written from memory; a wrong number stops the apply at that chart. Check with `helm search repo <chart> --versions` |
| One NAT gateway | not zone-resilient; for production use one per zone |
| `t3.medium` nodes | small: each has limited pod slots; the stack is tight |

## 10. Cost drivers (what you pay for)

EKS control plane (about 73 USD/month), 5 `t3.medium` servers, 1 NAT gateway plus data, 2 load balancers
(public app + team tools), EBS disks, CloudWatch logs. Destroy when you finish.
