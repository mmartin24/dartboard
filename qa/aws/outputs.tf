output "clusters" {
  value = {
    upstream = module.upstream_cluster.config
    downstream = [for cluster in module.downstream_clusters : cluster.config]
  }
}
