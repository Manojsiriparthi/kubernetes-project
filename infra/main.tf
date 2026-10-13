locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.availability_zone_count
  tags         = local.common_tags
}

module "eks_cluster" {
  source = "./modules/eks-cluster"

  cluster_name                          = "${var.project_name}-eks"
  cluster_version                       = var.kubernetes_version
  vpc_id                                = module.networking.vpc_id
  control_plane_subnet_ids              = module.networking.private_subnet_ids
  cluster_additional_security_group_ids = [module.networking.cluster_security_group_id]
  cluster_endpoint_public_access_cidrs  = var.cluster_endpoint_public_access_cidrs
  cluster_log_retention_days            = var.cluster_log_retention_days
  tags                                  = local.common_tags
}

module "eks_managed_addons" {
  source = "./modules/eks-managed-addons"

  cluster_name        = module.eks_cluster.cluster_name
  cluster_version     = var.kubernetes_version
  cluster_oidc_issuer = module.eks_cluster.cluster_oidc_issuer_url
  cluster_oidc_arn    = module.eks_cluster.oidc_provider_arn
  tags                = local.common_tags
}

module "eks_nodes" {
  source = "./modules/eks-nodes"

  project_name            = var.project_name
  cluster_name            = module.eks_cluster.cluster_name
  cluster_version         = var.kubernetes_version
  node_security_group_ids = module.networking.node_security_group_ids
  public_subnet_ids       = module.networking.public_subnet_ids
  application_subnet_ids  = module.networking.private_subnet_ids
  database_subnet_ids     = module.networking.database_subnet_ids
  public_node_group       = var.public_node_group
  application_node_group  = var.application_node_group
  database_node_group     = var.database_node_group
  node_volume_size_gib    = var.node_volume_size_gib
  tags                    = local.common_tags

  depends_on = [module.eks_cluster, module.eks_managed_addons]
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "postgres" {
  name                 = "${var.project_name}-postgres"
  image_tag_mutability = "IMMUTABLE"

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

output "eks_addon_roles" {
  value = {
    vpc_cni    = module.eks_managed_addons.role_arns.vpc_cni
    ebs_csi    = module.eks_managed_addons.role_arns.ebs_csi
    cloudwatch = module.eks_managed_addons.role_arns.cloudwatch
  }
  description = "IRSA role ARNs for EKS-managed add-ons."
}

output "frontend_ecr_repository_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "Push the frontend image to this repository."
}

output "backend_ecr_repository_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "Push the backend image to this repository."
}

output "postgres_ecr_repository_url" {
  value       = aws_ecr_repository.postgres.repository_url
  description = "Push the PostgreSQL image to this private repository for database-tier pulls."
}
