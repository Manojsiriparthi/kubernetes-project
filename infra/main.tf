# Root module: wires the building blocks together.
# Order on apply (reverse on destroy): networking -> eks_cluster -> eks_nodes -> eks_addons.
locals {
  # Tags applied to every AWS resource for cost tracking and ownership.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# VPC, subnets, gateways, route tables and the database security group.
module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.availability_zone_count
  tags         = local.common_tags
}

# EKS control plane (IAM role, OIDC, logs, encryption, access entries).
module "eks_cluster" {
  source = "./modules/eks-cluster"

  cluster_name                          = "${var.project_name}-eks"
  cluster_version                       = var.kubernetes_version
  vpc_id                                = module.networking.vpc_id
  control_plane_subnet_ids              = module.networking.private_subnet_ids
  cluster_endpoint_public_access_cidrs  = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_public_access        = var.cluster_endpoint_public_access
  cluster_admin_principal_arns          = var.cluster_admin_principal_arns
  cluster_developer_principal_arns      = var.cluster_developer_principal_arns
  cluster_viewer_principal_arns         = var.cluster_viewer_principal_arns
  cluster_log_retention_days            = var.cluster_log_retention_days
  tags                                  = local.common_tags

  # Whole network (routes, NAT, SGs) is ready before the cluster; destroyed after it.
  depends_on = [module.networking]
}

# Managed node groups: public (edge), application (frontend/backend) and database.
module "eks_nodes" {
  source = "./modules/eks-nodes"

  project_name            = var.project_name
  cluster_name            = module.eks_cluster.cluster_name
  cluster_version         = var.kubernetes_version
  public_subnet_ids       = module.networking.public_subnet_ids
  application_subnet_ids  = module.networking.private_subnet_ids
  database_subnet_ids     = module.networking.database_subnet_ids
  public_node_group       = var.public_node_group
  application_node_group  = var.application_node_group
  database_node_group     = var.database_node_group
  node_volume_size_gib    = var.node_volume_size_gib
  tags                    = local.common_tags
  network_addons_ready    = module.eks_addons.network_addons_ready

  depends_on = [module.networking, module.eks_cluster]
}

# Cluster add-ons: vpc-cni, kube-proxy, coredns, EBS CSI, CloudWatch, plus Helm charts
# (load balancer controller, autoscaler, metrics-server, VPA, secrets CSI driver).
module "eks_addons" {
  source = "./modules/eks-addons"

  project_name        = var.project_name
  cluster_name        = module.eks_cluster.cluster_name
  cluster_version     = var.kubernetes_version
  cluster_oidc_issuer = module.eks_cluster.cluster_oidc_issuer_url
  cluster_oidc_arn    = module.eks_cluster.oidc_provider_arn
  region              = var.region
  vpc_id              = module.networking.vpc_id
  team_access_cidrs   = var.team_access_cidrs
  team_certificate_arn = var.team_certificate_arn
  alertmanager_slack_webhook_url = var.alertmanager_slack_webhook_url
  tags                = local.common_tags

  # coredns and ebs-csi need running nodes to become ACTIVE.
  node_group_names = module.eks_nodes.node_group_names
}

# Private ECR repositories for the application images (tags are immutable, scanned on push).
# force_delete lets terraform destroy remove a repository even when it still holds images.
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

output "region" {
  value       = var.region
  description = "AWS region containing the cluster."
}

output "cluster_name" {
  value       = module.eks_cluster.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.eks_cluster.cluster_endpoint
  description = "EKS Kubernetes API endpoint."
}

output "vpc_id" {
  value       = module.networking.vpc_id
  description = "VPC ID."
}

output "node_groups" {
  value       = module.eks_nodes.node_group_names
  description = "EKS managed node group names."
}

output "node_roles" {
  value       = module.eks_nodes.node_role_arns
  description = "IAM role ARNs used by the three managed node groups."
}

output "grafana_admin_password" {
  value       = module.eks_addons.grafana_admin_password
  sensitive   = true
  description = "Grafana admin password (terraform output -raw grafana_admin_password)."
}

output "eks_addon_roles" {
  value       = module.eks_addons.role_arns
  description = "IRSA role ARNs for EKS add-ons."
}

output "frontend_ecr_repository_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "Push the frontend image to this repository."
}

output "backend_ecr_repository_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "Push the backend image to this repository."
}
