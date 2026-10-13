variable "project_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "node_security_group_ids" {
  type = map(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "application_subnet_ids" {
  type = list(string)
}

variable "database_subnet_ids" {
  type = list(string)
}

variable "public_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "application_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "database_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "node_volume_size_gib" {
  type = number
}

variable "tags" {
  type = map(string)
}
