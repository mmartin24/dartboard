provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

module "network" {
  source               = "./modules/aws/network"
  project_name         = var.project_name
  region               = var.region
  availability_zone    = var.availability_zone
  existing_vpc_name    = var.existing_vpc_name
  bastion_host_ami     = length(var.bastion_host_ami) > 0 ? var.bastion_host_ami : null
  bastion_host_instance_type = var.bastion_host_instance_type
  ssh_bastion_user     = var.ssh_bastion_user
  ssh_public_key_path  = var.ssh_public_key_path
  ssh_private_key_path = var.ssh_private_key_path
  ssh_prefix_list      = var.ssh_prefix_list
}

module "upstream_cluster" {
  source                      = "./modules/generic/rke2"
  project_name                = var.project_name
  name                        = "upstream"
  server_count                = var.upstream_cluster.server_count
  agent_count                 = var.upstream_cluster.agent_count
  distro_version              = var.upstream_cluster.distro_version
  reserve_node_for_monitoring = var.upstream_cluster.reserve_node_for_monitoring
  enable_audit_log            = var.upstream_cluster.enable_audit_log
  public                      = var.upstream_cluster.public_ip

  sans                      = ["upstream.local.gd"]
  local_kubernetes_api_port = var.first_kubernetes_api_port
  tunnel_app_http_port      = var.first_app_http_port
  tunnel_app_https_port     = var.first_app_https_port
  ssh_private_key_path      = var.ssh_private_key_path
  ssh_user                  = var.ssh_user
  network_config            = module.network.config
  node_module_variables     = var.upstream_cluster.node_module_variables
  datastore_endpoint        = null
}

locals {
  downstream_clusters = flatten([
    for i, template in var.downstream_cluster_templates : [
      for j in range(template.cluster_count) : merge(template, { name = "downstream-${i}-${j}" })
  ] if template.cluster_count > 0])
}

module "downstream_clusters" {
  count                       = length(local.downstream_clusters)
  source                      = "./modules/generic/k3s"
  project_name                = var.project_name
  name                        = local.downstream_clusters[count.index].name
  server_count                = local.downstream_clusters[count.index].server_count
  agent_count                 = local.downstream_clusters[count.index].agent_count
  distro_version              = local.downstream_clusters[count.index].distro_version
  reserve_node_for_monitoring = local.downstream_clusters[count.index].reserve_node_for_monitoring
  enable_audit_log            = local.downstream_clusters[count.index].enable_audit_log
  public                      = local.downstream_clusters[count.index].public_ip

  sans                      = ["${local.downstream_clusters[count.index].name}.local.gd"]
  max_pods                  = local.downstream_clusters[count.index].max_pods
  node_cidr_mask_size       = local.downstream_clusters[count.index].node_cidr_mask_size
  local_kubernetes_api_port = var.first_kubernetes_api_port + 1 + count.index
  tunnel_app_http_port      = var.first_app_http_port + 1 + count.index
  tunnel_app_https_port     = var.first_app_https_port + 1 + count.index
  ssh_private_key_path      = var.ssh_private_key_path
  ssh_user                  = var.ssh_user
  network_config            = module.network.config
  node_module_variables     = local.downstream_clusters[count.index].node_module_variables
}
