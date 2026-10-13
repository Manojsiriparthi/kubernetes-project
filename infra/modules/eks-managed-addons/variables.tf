variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "cluster_oidc_issuer" {
  type = string
}

variable "cluster_oidc_arn" {
  type = string
}

variable "tags" {
  type = map(string)
}
