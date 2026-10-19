variable "project_name" {
  description = "A prefix for names of objects created by this module"
  default     = "st-local"
}

variable "upstream_cluster" {
  description = "Upstream cluster configuration"
  type        = any
}

variable "downstream_cluster_templates" {
  description = "List of downstream cluster configurations"
  type        = list(any)
}

variable "first_kubernetes_api_port" {
  description = "Port number where the Kubernetes API of the first cluster is published locally. Other clusters' ports are published in successive ports"
  default     = 6445
}

variable "first_app_http_port" {
  description = "Port number where the first server's port 80 is published locally. Other clusters' ports are published in successive ports"
  default     = 8080
}

variable "first_app_https_port" {
  description = "Port number where the first server's port 443 is published locally. Other clusters' ports are published in successive ports"
  default     = 8443
}
