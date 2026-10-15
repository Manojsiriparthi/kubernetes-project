# Inputs for the EKS cluster module.

# Name of the EKS cluster.
variable "cluster_name" {
  type = string
}

# Kubernetes version of the control plane.
variable "cluster_version" {
  type = string
}

# VPC the cluster lives in.
variable "vpc_id" {
  type = string
}

# Subnets for the control plane network interfaces (the private subnets).
variable "control_plane_subnet_ids" {
  type = list(string)
}

# Whether the Kubernetes API is also reachable from the internet (still limited to the CIDRs below).
variable "cluster_endpoint_public_access" {
  type = bool
}

# IAM ARNs that get cluster-admin.
variable "cluster_admin_principal_arns" {
  type = list(string)
}

# IAM ARNs that can edit workloads in the school-demo namespace only.
variable "cluster_developer_principal_arns" {
  type = list(string)
}

# IAM ARNs with read-only access to the whole cluster.
variable "cluster_viewer_principal_arns" {
  type = list(string)
}

# Trusted public IP ranges allowed to reach the public API endpoint.
variable "cluster_endpoint_public_access_cidrs" {
  type = list(string)
}

# Days to keep control-plane logs in CloudWatch.
variable "cluster_log_retention_days" {
  type = number
}

variable "tags" {
  type = map(string)
}
