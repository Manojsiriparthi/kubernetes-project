# EKS control plane: cluster version, IAM role, OIDC, logging, encryption and who can access it.

locals {
  # Each *_access_entries map turns a list of IAM ARNs into EKS access entries with an AWS-managed policy.
  # Cluster-admin on the whole cluster.
  admin_access_entries = {
    for arn in var.cluster_admin_principal_arns : replace(arn, "/[^a-zA-Z0-9]/", "-") => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Edit rights limited to the school-demo namespace.
  developer_access_entries = {
    for arn in var.cluster_developer_principal_arns : replace(arn, "/[^a-zA-Z0-9]/", "-") => {
      principal_arn = arn
      policy_associations = {
        edit = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "namespace", namespaces = ["school-demo"] }
        }
      }
    }
  }

  # Read-only on the whole cluster.
  viewer_access_entries = {
    for arn in var.cluster_viewer_principal_arns : replace(arn, "/[^a-zA-Z0-9]/", "-") => {
      principal_arn = arn
      policy_associations = {
        view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

# Community EKS module: creates the cluster, its IAM role, KMS key, log group and OIDC provider.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = var.vpc_id

  control_plane_subnet_ids = var.control_plane_subnet_ids
  subnet_ids               = var.control_plane_subnet_ids

  # Cluster IAM role
  iam_role_name            = "${var.cluster_name}-cluster-role"
  iam_role_use_name_prefix = false

  # Worker nodes are managed in eks-nodes and use the EKS primary security group.
  create_node_security_group = false

  # API endpoint: private always on, public restricted to trusted CIDRs.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Access via EKS access entries only (no aws-auth ConfigMap).
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  access_entries                           = merge(local.admin_access_entries, local.developer_access_entries, local.viewer_access_entries)

  # Control-plane logging to CloudWatch.
  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # Envelope encryption of Kubernetes secrets with a rotated customer-managed key.
  create_kms_key            = true
  enable_kms_key_rotation   = true
  kms_key_deletion_window_in_days = 30
  cluster_encryption_config = { resources = ["secrets"] }

  # IRSA (OIDC provider).
  enable_irsa = true

  # Standard (not extended) support keeps upgrade costs predictable.
  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  tags = var.tags
}
