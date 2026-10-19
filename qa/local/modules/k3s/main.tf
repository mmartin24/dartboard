terraform {
  required_providers {
    k3d = {
      source = "moio/k3d"
    }
  }
}

// This copy only supports var.datastore == "embedded_etcd" (the module
// default): the mariadb/postgres/kine external-datastore docker_container
// resources from the upstream tofu/modules/k3d/k3s module were dropped here
// since they're unused for that case, and dropping them avoids needing the
// "docker" provider (and its v2-vs-v3 schema) in this file at all.

resource "k3d_cluster" "cluster" {
  count = var.server_count > 0 ? 1 : 0
  name  = "${var.project_name}-${var.name}"
  servers    = var.server_count
  agents     = var.agent_count

  // hardcode, so that cluster can be re-created and run from previous datastore
  token = "secretToken"

  image   = var.image != null ? var.image : "docker.io/rancher/k3s:${replace(var.distro_version, "+", "-")}"
  network = var.network_config.network_name

  k3d {
    disable_load_balancer = true
  }

  kubeconfig {
    update_default_kubeconfig = false
    switch_current_context    = false
  }

  volume {
    source       = "/sys"
    destination  = "/host/sys"
    node_filters = []
  }

  volume {
    source       = "/var/log/k3d/audit"
    destination  = "/var/log/kubernetes/audit"
    node_filters = ["server:*"]
  }

  volume {
    source       = "/var/lib/k3d/audit"
    destination  = "/var/lib/rancher/k3s/server/manifests/audit"
    node_filters = ["server:*"]
  }

  k3s {
    dynamic "extra_args" {
      for_each = concat(
        var.enable_metrics == false ? [
          {
            arg          = "--disable=metrics-server",
            node_filters = ["server:*"]
          }
        ] : [],
        // if datastore requires an external kine instance, point to it
        var.datastore == "mariadb" || var.datastore == "postgres" ? [
          {
            arg          = "--datastore-endpoint=http://kine:2379",
            node_filters = ["server:*"]
          }
        ] : [],
        // normally k3s defaults to sqlite for 1-node clusters and embedded etcd for multi-node ones
        // it is possible to force use of the embedded etcd for 1-node clusters via --cluster-init
        var.datastore == "embedded_etcd" && var.server_count == 1 && var.agent_count == 0 ? [
          {
            arg          = "--cluster-init",
            node_filters = ["server:0"]
          }
        ] : [],
        var.enable_pprof ? [
          {
            arg          = "--enable-pprof",
            node_filters = ["server:*"]
          }
        ] : [],
        var.log_level != null ? [
          {
            arg          = "-v=${var.log_level}",
            node_filters = ["server:*"]
          }
        ] : [],
        [
          for san in var.sans :
          {
            arg          = "--tls-san=${san}",
            node_filters = ["server:*"]
          }
        ],
        var.enable_audit_log ? flatten([
          {
            arg          = "--kube-apiserver-arg=audit-policy-file=/var/lib/rancher/k3s/server/manifests/audit/audit.yaml",
            node_filters = ["server:*"]
          },
          [for i in range(0, var.server_count) : {
            arg          = "--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit/audit_server_${i}.log",
            node_filters = ["server:${i}"]
          }],
        ]) : [],
        var.reserve_node_for_monitoring ? [
          {
            arg          = "--node-label=monitoring=true",
            node_filters = ["agent:0"]
          },
          {
            arg          = "--node-taint=morning=true:NoSchedule",
            node_filters = ["agent:0"]
          },
        ] : [],
      )
      content {
        arg          = extra_args.value["arg"]
        node_filters = extra_args.value["node_filters"]
      }
    }
  }

  registries {
    config = yamlencode({
      mirrors = {
        for registry in var.network_config.pull_proxy_registries :
        registry.name => { endpoints = ["http://${registry.address}"] }
      }
    })
  }

  env {
    key          = "GOGC"
    value        = tostring(var.gogc)
    node_filters = ["server:*"]
  }

  kube_api {
    host_port = var.local_kubernetes_api_port
  }

  dynamic "port" {
    for_each = concat([
      {
        host_port : var.tunnel_app_http_port,
        container_port : 80,
        node_filters : ["server:0:direct"]
      },
      {
        host_port : var.tunnel_app_https_port,
        container_port : 443,
        node_filters : ["server:0:direct"]
      },
      ],
      var.enable_metrics ?
      [
        for i in range(0, var.server_count) :
        {
          host_port : var.first_metrics_port + i,
          container_port : 10250,
          node_filters = ["server:${i}:direct"]
        }
      ] : [],
      var.enable_metrics ?
      [
        for i in range(0, var.agent_count) :
        [
          {
            host_port : var.first_metrics_port + var.server_count + i,
            container_port : 10250,
            node_filters = ["agent:${i}:direct"]
          }
        ]
      ] : [],
    )
    content {
      host_port      = port.value["host_port"]
      container_port = port.value["container_port"]
      node_filters   = port.value["node_filters"]
    }
  }
}

locals {
  local_kubernetes_api_url = nonsensitive(k3d_cluster.cluster[0].credentials[0].host)
  k3d_cluster_name = "${var.project_name}-${var.name}"
  // resolvable from other containers on the same docker network (e.g. another
  // k3d cluster's pods), unlike local_kubernetes_api_url above which only
  // resolves from the host running OpenTofu
  private_kubernetes_api_url = "https://k3d-${var.project_name}-${var.name}-server-0:6443"
}

resource "local_file" "kubeconfig" {
  count = var.server_count > 0 ? 1 : 0
  content = yamlencode({
    apiVersion = "v1"
    clusters = [
      {
        cluster = {
          certificate-authority-data = base64encode(k3d_cluster.cluster[0].credentials[0].cluster_ca_certificate)
          server                     = local.local_kubernetes_api_url
        }
        name = "k3d-${local.k3d_cluster_name}"
      }
    ]
    contexts = [
      {
        context = {
          cluster = "k3d-${local.k3d_cluster_name}"
          user : "admin@k3d-${local.k3d_cluster_name}"
        }
        name = "k3d-${local.k3d_cluster_name}"
      }
    ]
    current-context = "k3d-${local.k3d_cluster_name}"
    kind            = "Config"
    preferences     = {}
    users = [
      {
        user = {
          client-certificate-data : base64encode(k3d_cluster.cluster[0].credentials[0].client_certificate)
          client-key-data : base64encode(k3d_cluster.cluster[0].credentials[0].client_key)
        }
        name : "admin@k3d-${local.k3d_cluster_name}"
      }
    ]
  })

  filename        = "${path.root}/${terraform.workspace}_config/${var.name}.yaml"
  file_permission = "0700"
}

// Same as local_file.kubeconfig above, but addressed so that OTHER k3d
// clusters' pods (sharing the same docker network) can reach this cluster's
// API server -- needed for Fleet's static-kubeconfig cluster registration,
// where the fleet-controller on "upstream" dials out to each downstream
// cluster directly using this kubeconfig.
resource "local_file" "kubeconfig-direct" {
  count = var.server_count > 0 ? 1 : 0
  content = yamlencode({
    apiVersion = "v1"
    clusters = [
      {
        cluster = {
          certificate-authority-data = base64encode(k3d_cluster.cluster[0].credentials[0].cluster_ca_certificate)
          server                     = local.private_kubernetes_api_url
        }
        name = "k3d-${local.k3d_cluster_name}"
      }
    ]
    contexts = [
      {
        context = {
          cluster = "k3d-${local.k3d_cluster_name}"
          user : "admin@k3d-${local.k3d_cluster_name}"
        }
        name = "k3d-${local.k3d_cluster_name}"
      }
    ]
    current-context = "k3d-${local.k3d_cluster_name}"
    kind            = "Config"
    preferences     = {}
    users = [
      {
        user = {
          client-certificate-data : base64encode(k3d_cluster.cluster[0].credentials[0].client_certificate)
          client-key-data : base64encode(k3d_cluster.cluster[0].credentials[0].client_key)
        }
        name : "admin@k3d-${local.k3d_cluster_name}"
      }
    ]
  })

  filename        = "${path.root}/${terraform.workspace}_config/${var.name}-direct.yaml"
  file_permission = "0700"
}
