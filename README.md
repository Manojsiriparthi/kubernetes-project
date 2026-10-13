# Sree Chaitanya International School — Kubernetes teaching project

A classroom-sized example of a student portal running on Amazon EKS. It demonstrates the path from an AWS network and Kubernetes nodes to scheduled pods, services, persistent storage, and a public load balancer.

> **Demo only:** the student records and marks are fictitious. Do not use this app for real student data, production traffic, or real credentials. The example has no authentication, authorization at the application layer, TLS, backups, high availability for PostgreSQL, or production hardening.

## Architecture

```text
Browser
  │ HTTP
  ▼
Internet-facing AWS Network Load Balancer
  │
  ▼
frontend Service (LoadBalancer) ── frontend Deployment (2 pods, private application nodes)
                                          │ /api proxy
                                          ▼
                                backend Service (ClusterIP)
                                          │
                                backend Deployment (2 pods)
                                          │ PostgreSQL protocol
                                          ▼
                                  postgres Service (ClusterIP)
                                          │
                           PostgreSQL StatefulSet (1 pod)
                                          │
                             encrypted gp3 EBS persistent volume

EKS control plane ── managed node groups: public (3), application (3), database (3)
                                  │
          EBS CSI · CloudWatch Observability · Prometheus/Grafana
             Cluster Autoscaler · AWS Load Balancer Controller · OIDC/IRSA
```

The public node group is separate; frontend/backend and monitoring pods are pinned to private application nodes, and PostgreSQL is pinned to the tainted database group. Nodes in the public subnets receive public IPs for bootstrap/egress; application nodes use per-AZ NAT gateways and database nodes use private AWS VPC endpoints. PostgreSQL uses a private ECR image so database subnets do not need internet egress. Cross-node security-group rules allow Kubernetes pod networking; workload placement is controlled by node labels and the database taint, not by a strict network firewall between pods. The public AWS load balancer is not a pod. The database is a **single** PostgreSQL instance with a persistent volume, not a replicated/HA database. The default nine on-demand `m7i.large` nodes, three NAT gateways, EKS control plane, load balancers, storage, and monitoring can incur substantial AWS charges.

## Project layout

- `infra/` — Terraform VPC, EKS, managed node groups, EKS add-ons, IRSA roles, controllers, monitoring, and ECR repositories.
- `application/backend/` — Flask API, PostgreSQL initialization SQL, and backend Dockerfile.
- `application/frontend/` — responsive school portal, Nginx API proxy, and frontend Dockerfile.
- `application/postgres/` — PostgreSQL image that packages the demo schema/seed data for private ECR pulls.
- `kubernetes/` — namespace, sample RBAC, database, backend, and frontend resources.
- `docker-compose.yml` — local end-to-end application test with PostgreSQL, backend, and frontend.
- `infra/bootstrap-state.ps1` / `infra/bootstrap-state.sh` — create the encrypted, versioned S3 backend bucket and ignored backend config.

## 1. Test the application locally with Docker Compose

Install Docker Desktop (Windows/macOS) or Docker Engine with the Compose plugin (Linux). From the repository root, build and start the PostgreSQL database, Flask backend, and frontend:

```powershell
docker compose -f .\docker-compose.yml up --build
```

```bash
docker compose -f docker-compose.yml up --build
```

Compose waits for PostgreSQL and the backend health checks before starting dependent services. Open [http://localhost:8080](http://localhost:8080), look up the seeded demo student **Ananya Rao**, or register a fictional student to create a sample hall ticket and marks. The database uses a named volume, so records remain after stopping the containers.

Stop the stack with `Ctrl+C`, then run `docker compose -f docker-compose.yml down`. To remove the local database and its demo records too, run `docker compose -f docker-compose.yml down --volumes`. The default database password in the Compose file is for local classroom testing only; override it with the `POSTGRES_PASSWORD` environment variable if needed. Do not use real student records or this setup in production.

## 2. Create AWS infrastructure

Install Terraform (1.10+), Git, AWS CLI v2, Docker, and kubectl. Configure AWS credentials with permissions to create the listed resources and an EKS administrator identity that can use the cluster. The EKS cluster is in `us-east-1` by default and needs three available Availability Zones.

Copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars`, then replace `203.0.113.10/32` with your own trusted public IP in CIDR notation. The EKS API is public but restricted to that CIDR. Do not open it to `0.0.0.0/0`. Also copy `infra/addons/terraform.tfvars.example` to `infra/addons/terraform.tfvars`; update its region, project name, and cluster name if you changed those values in the foundation variables.

Terraform uses two roots because AWS resources and Kubernetes/Helm resources need different provider lifecycles. On Linux/macOS, create the state bucket and initialize the AWS/EKS foundation from the repository root:

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
cp infra/addons/terraform.tfvars.example infra/addons/terraform.tfvars
# Edit infra/terraform.tfvars and set your own public IP/CIDR.
bash infra/bootstrap-state.sh
terraform -chdir=infra init -backend-config=backend.hcl
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan
terraform -chdir=infra apply
```

On Windows PowerShell, the equivalent setup is:

```powershell
Copy-Item .\infra\terraform.tfvars.example .\infra\terraform.tfvars
Copy-Item .\infra\addons\terraform.tfvars.example .\infra\addons\terraform.tfvars
# Edit infra\terraform.tfvars and set your public IP/CIDR before proceeding.
.\infra\bootstrap-state.ps1 -Region us-east-1
terraform -chdir=infra init -backend-config=backend.hcl
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan
terraform -chdir=infra apply
```

After the cluster and nodes are ready, initialize and apply the in-cluster addons from the second Terraform root:
Run this as the same AWS identity that created the cluster (or grant that identity an EKS access entry with administrative access), from a host that can reach the cluster's private endpoint or the trusted public endpoint.

```bash
terraform -chdir=infra/addons init \
  -backend-config=../backend.hcl \
  -backend-config=key=school-demo/infra-addons/terraform.tfstate
terraform -chdir=infra/addons fmt -check
terraform -chdir=infra/addons validate
terraform -chdir=infra/addons plan
terraform -chdir=infra/addons apply
```

```powershell
terraform -chdir=infra/addons init `
  -backend-config=../backend.hcl `
  -backend-config="key=school-demo/infra-addons/terraform.tfstate"
terraform -chdir=infra/addons fmt -check
terraform -chdir=infra/addons validate
terraform -chdir=infra/addons plan
terraform -chdir=infra/addons apply
```

The state bootstrap creates/uses the `school-demo-terraform-state-513263709619-us-east-1` bucket and enables S3 versioning, server-side encryption, public-access blocking, and TLS-only access. Both Terraform roots use native S3 state locking with `use_lockfile = true` (Terraform 1.10+); no DynamoDB lock table is required. The bootstrap checks that your AWS credentials belong to account `513263709619`. Keep `infra/backend.hcl`, `infra/terraform.tfvars`, and `infra/addons/terraform.tfvars` out of Git; all are ignored. The bootstrap bucket is separate from the resources managed by the Terraform states and is not deleted by `terraform destroy`.

The foundation root creates the three subnet tiers and per-AZ NAT, private VPC endpoints for ECR/STS/EC2/CloudWatch and S3, EKS control plane and node groups, OIDC provider, VPC CNI/EBS CSI/CloudWatch Observability managed add-ons with IRSA, and three scanned ECR repositories. The addons root installs the AWS Load Balancer Controller, Cluster Autoscaler with scale permissions limited to tagged groups, a gp3 StorageClass, and Prometheus/Grafana with persistent storage. The EKS cluster creator is granted cluster-admin access; the namespaced Kubernetes observer role in `kubernetes/rbac.yaml` is a separate RBAC teaching example.

Configure kubectl and check the nodes:

```bash
CLUSTER="$(terraform -chdir=infra output -raw cluster_name)"
aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER"
kubectl get nodes -L workload
kubectl get pods -n kube-system
kubectl get pods -n monitoring
terraform -chdir=infra/addons output -raw grafana_admin_password
```

```powershell
$Cluster = terraform -chdir=infra output -raw cluster_name
aws eks update-kubeconfig --region us-east-1 --name $Cluster
kubectl get nodes -L workload
kubectl get pods -n kube-system
kubectl get pods -n monitoring
terraform -chdir=infra/addons output -raw grafana_admin_password
```

Store the displayed Grafana password securely. If no `grafana_admin_password` is set in `infra/addons/terraform.tfvars`, Terraform generates one and records it in the encrypted remote state.
Grafana is internal-only by default; connect to it with `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` and visit `http://localhost:3000`.

## 3. Build and push the application images

Build from the repository root and push all three containers to the private ECR repositories output by Terraform. The PostgreSQL image includes its initialization SQL so the isolated database subnet does not need public internet access:

```bash
REGION=us-east-1
FRONTEND_REPO="$(terraform -chdir=infra output -raw frontend_ecr_repository_url)"
BACKEND_REPO="$(terraform -chdir=infra output -raw backend_ecr_repository_url)"
POSTGRES_REPO="$(terraform -chdir=infra output -raw postgres_ecr_repository_url)"
REGISTRY="${BACKEND_REPO%%/*}"
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "${BACKEND_REPO}:1.0.0" application/backend
docker push "${BACKEND_REPO}:1.0.0"
docker build -t "${FRONTEND_REPO}:1.0.0" application/frontend
docker push "${FRONTEND_REPO}:1.0.0"
docker build -t "${POSTGRES_REPO}:1.0.0" \
  -f application/postgres/Dockerfile application
docker push "${POSTGRES_REPO}:1.0.0"
```

```powershell
$Region = "us-east-1"
$FrontendRepo = terraform -chdir=infra output -raw frontend_ecr_repository_url
$BackendRepo = terraform -chdir=infra output -raw backend_ecr_repository_url
$PostgresRepo = terraform -chdir=infra output -raw postgres_ecr_repository_url
$Registry = ($BackendRepo -split "/")[0]
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $Registry

docker build -t "${BackendRepo}:1.0.0" .\application\backend
docker push "${BackendRepo}:1.0.0"
docker build -t "${FrontendRepo}:1.0.0" .\application\frontend
docker push "${FrontendRepo}:1.0.0"
docker build -t "${PostgresRepo}:1.0.0" -f .\application\postgres\Dockerfile .\application
docker push "${PostgresRepo}:1.0.0"
```

Update the deployment manifests to point at the pushed ECR images (the short image names are local classroom placeholders):
ECR tags are immutable; choose a new image tag when publishing an updated build.

```bash
sed -i "s|school-demo-backend:1.0.0|${BACKEND_REPO}:1.0.0|" kubernetes/backend.yaml
sed -i "s|school-demo-frontend:1.0.0|${FRONTEND_REPO}:1.0.0|" kubernetes/frontend.yaml
sed -i "s|school-demo-postgres:1.0.0|${POSTGRES_REPO}:1.0.0|" kubernetes/postgres.yaml
```

```powershell
$BackendManifest = ".\kubernetes\backend.yaml"
(Get-Content $BackendManifest -Raw).Replace("school-demo-backend:1.0.0", "${BackendRepo}:1.0.0") |
  Set-Content $BackendManifest -NoNewline
$FrontendManifest = ".\kubernetes\frontend.yaml"
(Get-Content $FrontendManifest -Raw).Replace("school-demo-frontend:1.0.0", "${FrontendRepo}:1.0.0") |
  Set-Content $FrontendManifest -NoNewline
$PostgresManifest = ".\kubernetes\postgres.yaml"
(Get-Content $PostgresManifest -Raw).Replace("school-demo-postgres:1.0.0", "${PostgresRepo}:1.0.0") |
  Set-Content $PostgresManifest -NoNewline
```

## 4. Deploy the Kubernetes application

Create the namespace and a demo-only password in a Kubernetes Secret. The password is generated for this shell session; production credentials should come from a managed secret service, not a command-line literal.

```bash
kubectl apply -f kubernetes/namespace.yaml
DB_PASSWORD="$(openssl rand -hex 24)"
DATABASE_URL="postgresql://school_app:${DB_PASSWORD}@postgres.school-demo.svc.cluster.local:5432/school"
kubectl create secret generic school-db -n school-demo \
  --from-literal=POSTGRES_DB=school \
  --from-literal=POSTGRES_USER=school_app \
  --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=DATABASE_URL="$DATABASE_URL"

kubectl apply -k .
kubectl get pods,services,pvc -n school-demo -o wide
kubectl rollout status statefulset/postgres -n school-demo
kubectl rollout status deployment/backend -n school-demo
kubectl rollout status deployment/frontend -n school-demo
```

```powershell
kubectl apply -f .\kubernetes\namespace.yaml
$DbPassword = [guid]::NewGuid().ToString("N")
$DatabaseUrl = "postgresql://school_app:${DbPassword}@postgres.school-demo.svc.cluster.local:5432/school"
kubectl create secret generic school-db -n school-demo `
  --from-literal=POSTGRES_DB=school `
  --from-literal=POSTGRES_USER=school_app `
  --from-literal=POSTGRES_PASSWORD=$DbPassword `
  --from-literal=DATABASE_URL=$DatabaseUrl

kubectl apply -k .
kubectl get pods,services,pvc -n school-demo -o wide
kubectl rollout status statefulset/postgres -n school-demo
kubectl rollout status deployment/backend -n school-demo
kubectl rollout status deployment/frontend -n school-demo
```

Terraform creates the `gp3` StorageClass, which provisions encrypted EBS volumes through the CSI driver. The first PostgreSQL initialization runs the SQL in `application/backend/init.sql` and inserts four demo students. The image's PostgreSQL entrypoint runs that script only when the data directory is new; changing the SQL later does not re-seed an existing PVC.

Wait for the AWS Network Load Balancer address:

```powershell
kubectl get service frontend -n school-demo --watch
```

Open the `EXTERNAL-IP`/hostname in a browser using `http://`. AWS provisioning can take a few minutes. Try **Student info** with `Ananya` / `Rao`, or register a demo student. Each new registration gets a hall ticket and five randomly generated demonstration marks; all marks are fictional.

## Classroom walkthrough

Useful commands for showing the pod/service/storage lifecycle:

```powershell
kubectl get pods -n school-demo -w
kubectl describe pod -n school-demo -l app=backend
kubectl get events -n school-demo --sort-by=.lastTimestamp
kubectl logs -n school-demo deployment/backend --follow
kubectl get endpoints -n school-demo
kubectl get pvc,pv -n school-demo
kubectl scale deployment/frontend -n school-demo --replicas=3
kubectl rollout history deployment/frontend -n school-demo
kubectl rollout undo deployment/frontend -n school-demo
```

To test the namespaced observer RBAC:

```powershell
kubectl auth can-i list pods -n school-demo --as=system:serviceaccount:school-demo:school-observer
kubectl auth can-i delete pods -n school-demo --as=system:serviceaccount:school-demo:school-observer
```

The first command should say `yes`; the second should say `no`. AWS IAM/OIDC roles used by controllers are separate from Kubernetes RoleBindings: IRSA lets a specific Kubernetes service account obtain only its assigned AWS permissions.

## Cleanup

Remove the application, then destroy the Terraform-managed AWS resources when the class is finished:

```powershell
kubectl delete -k .
terraform -chdir=infra/addons destroy
terraform -chdir=infra destroy
```

The database StorageClass uses `reclaimPolicy: Retain`, so the EBS volume can remain after the PVC is removed. Review and delete retained EBS volumes manually if the demo data is no longer needed. Check the AWS account for leftover load balancers, ECR images, and retained volumes. EKS, EC2 nodes, NAT Gateway, EBS, and load balancers can all incur charges while present.
