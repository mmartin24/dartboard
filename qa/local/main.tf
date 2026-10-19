module "network" {
  source       = "../../tofu/modules/k3d/network"
  project_name = var.project_name
}

module "upstream_cluster" {
  source                      = "./modules/k3s"
  project_name                = var.project_name
  name                        = "upstream"
  server_count                = var.upstream_cluster.server_count
  agent_count                 = var.upstream_cluster.agent_count
  distro_version              = var.upstream_cluster.distro_version
  reserve_node_for_monitoring = var.upstream_cluster.reserve_node_for_monitoring
  enable_audit_log            = var.upstream_cluster.enable_audit_log

  sans                      = ["upstream.local.gd"]
  local_kubernetes_api_port = var.first_kubernetes_api_port
  tunnel_app_http_port      = var.first_app_http_port
  tunnel_app_https_port     = var.first_app_https_port
  network_config            = module.network.config
}

locals {
  downstream_clusters = flatten([
    for i, template in var.downstream_cluster_templates : [
      for j in range(template.cluster_count) : merge(template, { name = "downstream-${i}-${j}" })
  ] if template.cluster_count > 0])
}

module "downstream_clusters" {
  count                       = length(local.downstream_clusters)
  source                      = "./modules/k3s"
  project_name                = var.project_name
  name                        = local.downstream_clusters[count.index].name
  server_count                = local.downstream_clusters[count.index].server_count
  agent_count                 = local.downstream_clusters[count.index].agent_count
  distro_version              = local.downstream_clusters[count.index].distro_version
  reserve_node_for_monitoring = local.downstream_clusters[count.index].reserve_node_for_monitoring
  enable_audit_log            = local.downstream_clusters[count.index].enable_audit_log

  sans                      = ["${local.downstream_clusters[count.index].name}.local.gd"]
  local_kubernetes_api_port = var.first_kubernetes_api_port + 1 + count.index
  tunnel_app_http_port      = var.first_app_http_port + 1 + count.index
  tunnel_app_https_port     = var.first_app_https_port + 1 + count.index
  network_config            = module.network.config
}
