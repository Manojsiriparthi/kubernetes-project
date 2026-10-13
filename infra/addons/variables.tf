variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "school-demo"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "cluster_name" {
  type    = string
  default = "school-demo-eks"
}

variable "grafana_admin_password" {
  description = "Optional Grafana administrator password. If unset, Terraform generates one."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.grafana_admin_password == null || length(var.grafana_admin_password) >= 24
    error_message = "If supplied, the Grafana password must be at least 24 characters."
  }
}
