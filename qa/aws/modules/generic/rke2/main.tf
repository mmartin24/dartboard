terraform {
  required_providers {
    ssh = {
      source = "loafoe/ssh"
    }
  }
}

data "http" "get_rke2" {
  url = "https://get.rke2.io"

  retry {
    attempts = 5
    min_delay_ms = 500
    max_delay_ms = 3000
  }

  lifecycle {
    postcondition {
      condition     = contains([200], self.status_code)
      error_message = "Status code invalid"
    }
  }
}

module "server_nodes" {
  count                       = var.server_count
  source                      = "../../aws/node"
  project_name                = var.project_name
  name                        = "${var.name}-server-${count.index}"
  ssh_private_key_path        = var.ssh_private_key_path
  ssh_user                    = var.ssh_user
  ssh_tunnels                 = count.index == 0 ? [
    [var.local_kubernetes_api_port, 6443],
    [var.tunnel_app_http_port, 80],
    [var.tunnel_app_https_port, 443],
  ] : []
  host_configuration_commands = ["cat /etc/os-release"]
  node_module_variables       = var.node_module_variables
  network_config              = var.network_config
  public                      = var.public
}

module "agent_nodes" {
  count                       = var.agent_count
  source                      = "../../aws/node"
  project_name                = var.project_name
  name                        = "${var.name}-agent-${count.index}"
  ssh_private_key_path        = var.ssh_private_key_path
  ssh_user                    = var.ssh_user
  ssh_tunnels                 = []
  host_configuration_commands = ["cat /etc/os-release"]
  node_module_variables       = var.agent_node_module_variables != null ? var.agent_node_module_variables : var.node_module_variables
  network_config              = var.network_config
  public                      = var.public
}

resource "ssh_sensitive_resource" "first_server_installation" {
  count        = var.server_count > 0 ? 1 : 0
  host         = module.server_nodes[0].private_name
  private_key  = file(var.ssh_private_key_path)
  user         = var.ssh_user
  bastion_host = var.network_config.ssh_bastion_host
  bastion_user = var.network_config.ssh_bastion_user
  timeout      = "600s"

  file {
    content = data.http.get_rke2.response_body
    destination = "${local.get_rke2_path}"
    permissions = "0700"
  }

  file {
    content = templatefile("${path.module}/install_rke2.sh", {
      get_rke2_path  = local.get_rke2_path
      distro_version = var.distro_version,
      sans           = concat([module.server_nodes[0].private_name], var.sans)
      type           = "server"
      token          = null
      server_url     = null
      labels         = []
      taints         = []

      client_ca_key          = tls_private_key.client_ca_key.private_key_pem
      client_ca_cert         = tls_self_signed_cert.client_ca_cert.cert_pem
      server_ca_key          = tls_private_key.server_ca_key.private_key_pem
      server_ca_cert         = tls_self_signed_cert.server_ca_cert.cert_pem
      request_header_ca_key  = tls_private_key.request_header_ca_key.private_key_pem
      request_header_ca_cert = tls_self_signed_cert.request_header_ca_cert.cert_pem
      max_pods               = var.max_pods
      node_cidr_mask_size    = var.node_cidr_mask_size
    })
    destination = "/tmp/install_rke2.sh"
    permissions = "0700"
  }

  file {
    content     = file("${path.module}/wait_for_k8s.sh")
    destination = "/tmp/wait_for_k8s.sh"
    permissions = "0700"
  }

  commands = [
    "sudo /tmp/install_rke2.sh > >(tee install_rke2.log) 2> >(tee install_rke2.err >&2)",
    "sudo /tmp/wait_for_k8s.sh",
    "sudo cat /var/lib/rancher/rke2/server/node-token",
  ]
}

resource "ssh_resource" "additional_server_installation" {
  depends_on = [ssh_sensitive_resource.first_server_installation]
  count      = max(0, var.server_count - 1)

  host         = module.server_nodes[count.index + 1].private_name
  private_key  = file(var.ssh_private_key_path)
  user         = var.ssh_user
  bastion_host = var.network_config.ssh_bastion_host
  bastion_user = var.network_config.ssh_bastion_user
  timeout      = "600s"

  file {
    content = data.http.get_rke2.response_body
    destination = "${local.get_rke2_path}"
    permissions = "0700"
  }

  file {
    content = templatefile("${path.module}/install_rke2.sh", {
      get_rke2_path  = local.get_rke2_path
      distro_version = var.distro_version,
      sans           = [module.server_nodes[count.index + 1].private_name]
      type           = "server"
      token          = ssh_sensitive_resource.first_server_installation[0].result
      server_url     = "https://${module.server_nodes[0].private_name}:9345"
      labels         = []
      taints         = []

      client_ca_key          = tls_private_key.client_ca_key.private_key_pem
      client_ca_cert         = tls_self_signed_cert.client_ca_cert.cert_pem
      server_ca_key          = tls_private_key.server_ca_key.private_key_pem
      server_ca_cert         = tls_self_signed_cert.server_ca_cert.cert_pem
      request_header_ca_key  = tls_private_key.request_header_ca_key.private_key_pem
      request_header_ca_cert = tls_self_signed_cert.request_header_ca_cert.cert_pem
      max_pods               = var.max_pods
      node_cidr_mask_size    = var.node_cidr_mask_size
    })
    destination = "/tmp/install_rke2.sh"
    permissions = "0700"
  }

  commands = [
    "sudo /tmp/install_rke2.sh > >(tee install_rke2.log) 2> >(tee install_rke2.err >&2)"
  ]
}

resource "ssh_resource" "agent_installation" {
  depends_on = [ssh_sensitive_resource.first_server_installation]
  count      = var.agent_count

  host         = module.agent_nodes[count.index].private_name
  private_key  = file(var.ssh_private_key_path)
  user         = var.ssh_user
  bastion_host = var.network_config.ssh_bastion_host
  bastion_user = var.network_config.ssh_bastion_user
  timeout      = "600s"

  file {
    content = data.http.get_rke2.response_body
    destination = "${local.get_rke2_path}"
    permissions = "0700"
  }

  file {
    content = templatefile("${path.module}/install_rke2.sh", {
      get_rke2_path  = local.get_rke2_path
      distro_version = var.distro_version,
      sans           = [module.agent_nodes[count.index].private_name]
      type           = "agent"
      token          = ssh_sensitive_resource.first_server_installation[0].result
      server_url     = "https://${module.server_nodes[0].private_name}:9345"
      labels = var.reserve_node_for_monitoring && count.index == 0 ? [
        { key : "monitoring", value : "true" }
      ] : []
      taints = var.reserve_node_for_monitoring && count.index == 0 ? [
        { key : "monitoring", value : "true", effect : "NoSchedule" }
      ] : []

      client_ca_key          = tls_private_key.client_ca_key.private_key_pem
      client_ca_cert         = tls_self_signed_cert.client_ca_cert.cert_pem
      server_ca_key          = tls_private_key.server_ca_key.private_key_pem
      server_ca_cert         = tls_self_signed_cert.server_ca_cert.cert_pem
      request_header_ca_key  = tls_private_key.request_header_ca_key.private_key_pem
      request_header_ca_cert = tls_self_signed_cert.request_header_ca_cert.cert_pem
      max_pods               = var.max_pods
      node_cidr_mask_size    = var.node_cidr_mask_size
    })
    destination = "/tmp/install_rke2.sh"
    permissions = "0700"
  }

  commands = [
    "sudo /tmp/install_rke2.sh > >(tee install_rke2.log) 2> >(tee install_rke2.err >&2)"
  ]
}

locals {
  get_rke2_path            = "/tmp/get_rke2.sh"
  local_kubernetes_api_url = "https://${var.sans[0]}:${var.local_kubernetes_api_port}"
  kubernetes_api_url = var.network_config.ssh_bastion_host == null ? "https://${module.server_nodes[0].public_name}:6443" : "https://${module.server_nodes[0].private_name}:6443"
}

resource "local_file" "ssh_script_servers" {
  count = var.server_count
  content = <<-EOT
    #!/bin/sh
    ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
      -i ${var.ssh_private_key_path} \
      %{if var.network_config.ssh_bastion_host != null~}
      -o ProxyCommand="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} -W %h:%p ${var.network_config.ssh_bastion_user}@${var.network_config.ssh_bastion_host}" ${var.ssh_user}@${module.server_nodes[count.index].private_name} \
      %{else~}
      ${var.ssh_user}@${module.server_nodes[count.index].public_name} \
      %{endif~}
      $@
  EOT

  filename = "${path.root}/${terraform.workspace}_config/ssh-to-${var.name}-server-${count.index}.sh"
}

resource "local_file" "ssh_script_agents" {
  count = var.agent_count
  content = <<-EOT
    #!/bin/sh
    ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
      -i ${var.ssh_private_key_path} \
      %{if var.network_config.ssh_bastion_host != null~}
      -o ProxyCommand="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} -W %h:%p ${var.network_config.ssh_bastion_user}@${var.network_config.ssh_bastion_host}" ${var.ssh_user}@${module.agent_nodes[count.index].private_name} \
      %{else~}
      ${var.ssh_user}@${module.agent_nodes[count.index].public_name} \
      %{endif~}
      $@
  EOT

  filename = "${path.root}/${terraform.workspace}_config/ssh-to-${var.name}-agent-${count.index}.sh"
}

resource "local_file" "open_tunnels" {
  count = var.server_count > 0 && length([
    [var.local_kubernetes_api_port, 6443],
    [var.tunnel_app_http_port, 80],
    [var.tunnel_app_https_port, 443],
  ]) > 0 ? 1 : 0
  content = templatefile("${path.module}/open-tunnels-to.sh", {
    ssh_bastion_host     = var.network_config.ssh_bastion_host
    ssh_bastion_user     = var.network_config.ssh_bastion_user
    ssh_tunnels          = [
      [var.local_kubernetes_api_port, 6443],
      [var.tunnel_app_http_port, 80],
      [var.tunnel_app_https_port, 443],
    ]
    private_name         = module.server_nodes[0].private_name
    public_name          = module.server_nodes[0].public_name
    ssh_user             = var.ssh_user
    ssh_private_key_path = var.ssh_private_key_path
  })

  filename = "${path.root}/${terraform.workspace}_config/open-tunnels-to-${var.name}-server-0.sh"
}

resource "local_file" "kubeconfig" {
  content = yamlencode({
    apiVersion = "v1"
    clusters = [
      {
        cluster = {
          certificate-authority-data = base64encode(tls_self_signed_cert.server_ca_cert.cert_pem)
          server                     = local.local_kubernetes_api_url
        }
        name = var.name
      }
    ]
    contexts = [
      {
        context = {
          cluster = var.name
          user = "admin@${var.name}"
        }
        name = var.name
      }
    ]
    current-context = var.name
    kind            = "Config"
    preferences     = {}
    users = [
      {
        user = {
          client-certificate-data : base64encode(tls_locally_signed_cert.master_user.cert_pem)
          client-key-data : base64encode(tls_private_key.master_user.private_key_pem)
        }
        name = "admin@${var.name}"
      }
    ]
  })

  filename        = "${path.root}/${terraform.workspace}_config/${var.name}.yaml"
  file_permission = "0700"
}

resource "local_file" "kubeconfig-direct" {
  content = yamlencode({
    apiVersion = "v1"
    clusters = [
      {
        cluster = {
          certificate-authority-data = base64encode(tls_self_signed_cert.server_ca_cert.cert_pem)
          server                     = local.kubernetes_api_url
        }
        name = var.name
      }
    ]
    contexts = [
      {
        context = {
          cluster = var.name
          user = "admin@${var.name}"
        }
        name = var.name
      }
    ]
    current-context = var.name
    kind            = "Config"
    preferences     = {}
    users = [
      {
        user = {
          client-certificate-data : base64encode(tls_locally_signed_cert.master_user.cert_pem)
          client-key-data : base64encode(tls_private_key.master_user.private_key_pem)
        }
        name = "admin@${var.name}"
      }
    ]
  })

  filename        = "${path.root}/${terraform.workspace}_config/${var.name}-direct.yaml"
  file_permission = "0700"
}
