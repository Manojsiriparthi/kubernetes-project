variable "project_name" {
  type = string
}

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

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

# Public IP ranges (office/VPN) allowed to reach the team-tools ALB (Argo CD, Prometheus, Grafana).
variable "team_access_cidrs" {
  type = list(string)
}

# Optional Slack incoming-webhook URL for alerts; leave null to see alerts only in the Alertmanager UI.
variable "alertmanager_slack_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

# Optional ACM certificate ARN to serve the team-tools ALB over HTTPS (requires your own domain).
variable "team_certificate_arn" {
  type    = string
  default = null
}

variable "tags" {
  type = map(string)
}
