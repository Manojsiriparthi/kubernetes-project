variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "control_plane_subnet_ids" {
  type = list(string)
}

variable "cluster_additional_security_group_ids" {
  type = list(string)
}

variable "cluster_endpoint_public_access_cidrs" {
  type = list(string)
}

variable "cluster_log_retention_days" {
  type = number
}

variable "tags" {
  type = map(string)
}
