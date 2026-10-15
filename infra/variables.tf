variable "region" {
  description = "AWS region for the cluster."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short prefix used in AWS resource names."
  type        = string
  default     = "school-demo"
}

variable "environment" {
  description = "Resource environment tag."
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "Non-overlapping VPC IPv4 CIDR."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 4, 11))
    error_message = "Specify a valid IPv4 CIDR with enough addresses for all three subnet tiers."
  }
}

variable "availability_zone_count" {
  description = "Number of availability zones used for each subnet tier."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 3 && var.availability_zone_count <= 4
    error_message = "Use three or four Availability Zones for this high-availability design."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version supported by the selected add-ons."
  type        = string
  default     = "1.35"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted administrator IPv4 CIDRs for the public EKS API endpoint. Keep the private endpoint enabled as well."
  type        = list(string)

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([for cidr in var.cluster_endpoint_public_access_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"])
    error_message = "Specify valid trusted public IPv4 CIDRs; 0.0.0.0/0 is not allowed."
  }
}

variable "cluster_endpoint_public_access" {
  description = "Expose the EKS API publicly (restricted to the trusted CIDRs). Set false for private-only access."
  type        = bool
  default     = true
}

variable "cluster_admin_principal_arns" {
  description = "IAM role/user ARNs granted cluster-admin through EKS access entries (in addition to the creator)."
  type        = list(string)
  default     = []
}

variable "cluster_developer_principal_arns" {
  description = "IAM role/user ARNs allowed to edit workloads in the school-demo namespace only."
  type        = list(string)
  default     = []
}

variable "cluster_viewer_principal_arns" {
  description = "IAM role/user ARNs with read-only access to the whole cluster."
  type        = list(string)
  default     = []
}

variable "team_access_cidrs" {
  description = "Trusted public IPv4 CIDRs (office/VPN, e.g. your IP as x.x.x.x/32) allowed to reach the team-tools ALB (Argo CD, Prometheus, Grafana)."
  type        = list(string)

  validation {
    condition     = length(var.team_access_cidrs) > 0 && alltrue([for cidr in var.team_access_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"])
    error_message = "Specify valid trusted IPv4 CIDRs; 0.0.0.0/0 is not allowed."
  }
}

variable "team_certificate_arn" {
  description = "Optional ACM certificate ARN for the team-tools ALB. Leave null for plain HTTP (testing only)."
  type        = string
  default     = null
}

variable "alertmanager_slack_webhook_url" {
  description = "Optional Slack incoming-webhook URL for Alertmanager notifications. Leave null to view alerts in the Alertmanager UI only."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_log_retention_days" {
  description = "Retention period for EKS control-plane logs."
  type        = number
  default     = 90
}

variable "node_volume_size_gib" {
  description = "Encrypted gp3 root volume size for each worker node."
  type        = number
  default     = 80

  validation {
    condition     = var.node_volume_size_gib >= 20 && var.node_volume_size_gib <= 16384
    error_message = "EKS worker root volumes must be between 20 and 16384 GiB."
  }
}

variable "public_node_group" {
  description = "Capacity settings for the edge/system node group in public subnets."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
  default = {
    instance_types = ["t3.medium"]
    min_size       = 1
    desired_size   = 1
    max_size       = 2
  }

  validation {
    condition     = length(var.public_node_group.instance_types) > 0 && var.public_node_group.min_size >= 1 && var.public_node_group.min_size <= var.public_node_group.desired_size && var.public_node_group.desired_size <= var.public_node_group.max_size
    error_message = "Public node group must define an instance type and satisfy 1 <= min_size <= desired_size <= max_size."
  }
}

variable "application_node_group" {
  description = "Capacity settings for frontend and backend workloads."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
  default = {
    instance_types = ["t3.medium"]
    min_size       = 3
    desired_size   = 3
    max_size       = 6
  }

  validation {
    condition     = length(var.application_node_group.instance_types) > 0 && var.application_node_group.min_size >= 1 && var.application_node_group.min_size <= var.application_node_group.desired_size && var.application_node_group.desired_size <= var.application_node_group.max_size
    error_message = "Application node group must define an instance type and satisfy 1 <= min_size <= desired_size <= max_size."
  }
}

variable "database_node_group" {
  description = "Capacity settings for database-only workloads."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
  default = {
    instance_types = ["t3.medium"]
    min_size       = 1
    desired_size   = 1
    max_size       = 1
  }

  validation {
    condition     = length(var.database_node_group.instance_types) > 0 && var.database_node_group.min_size >= 1 && var.database_node_group.min_size <= var.database_node_group.desired_size && var.database_node_group.desired_size <= var.database_node_group.max_size
    error_message = "Database node group must define an instance type and satisfy 1 <= min_size <= desired_size <= max_size."
  }
}
