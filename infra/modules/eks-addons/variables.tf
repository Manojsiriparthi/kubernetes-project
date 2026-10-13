variable "project_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_oidc_issuer" {
  type = string
}

variable "cluster_oidc_arn" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = null
}

variable "tags" {
  type = map(string)
}
