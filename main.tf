variable "ssh_pub_key" {}
variable "token" {}
variable "region" {}
variable "ssh_private_key" {}
variable "certificate_key" {}

provider "linode" {
  token = var.token
}

resource "random_string" "token_id" {
  length  = 6
  special = false
  upper   = false
}

resource "random_string" "token_secret" {
  length  = 16
  special = false
  upper   = false
}

locals {
  session_name     = "lintoast-remote"
  token            = "${random_string.token_id.result}.${random_string.token_secret.result}"
  bootstrap        = true
  masters          = 2
  workers          = 3
  pod_network_cidr = "10.0.1.0/16"
}

resource "random_password" "random_pass" {
  length  = 35
  special = true
  upper   = true
}


resource "linode_instance" "bootstrap" {
  label  = "master-3-bootstrap"
  region = var.region
  type   = "g6-standard-4"

  disk {
    label           = "ubuntu21.10"
    size            = 30000
    filesystem      = "ext4"
    image           = "linode/ubuntu21.10"
    authorized_keys = [var.ssh_pub_key]
    root_pass       = random_password.random_pass.result
  }

  config {
    label  = "04config"
    kernel = "linode/grub2"
    devices {
      sda {
        disk_label = "ubuntu21.10"
      }
    }
    root_device = "/dev/sda"
  }
  boot_config_label = "04config"

  private_ip = true
}

resource "linode_nodebalancer" "workspace_lb" {
  label                = "kubectl-${local.session_name}-lb"
  region               = var.region
  client_conn_throttle = 2
  tags                 = [local.session_name]
}

resource "linode_nodebalancer_config" "workspace_lb-kubectl" {
  nodebalancer_id = linode_nodebalancer.workspace_lb.id
  port            = 6443
  protocol        = "tcp"
}

resource "linode_nodebalancer_node" "bootstrap_lb_node" {
  nodebalancer_id = linode_nodebalancer.workspace_lb.id
  config_id       = linode_nodebalancer_config.workspace_lb-kubectl.id
  address         = "${linode_instance.bootstrap.private_ip_address}:6443"
  label           = local.session_name
  weight          = 100
}

resource "null_resource" "bootstrap_config" {
  triggers = {
    primary_change = linode_instance.bootstrap.ip_address
  }

  connection {
    host        = linode_instance.bootstrap.ip_address
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get -y update",
      "apt-get install -y apt-transport-https curl",
      "curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -",
      "echo 'deb https://apt.kubernetes.io/ kubernetes-xenial main' >/etc/apt/sources.list.d/kubernetes.list",
      "apt-get -y update",
      "apt-get install -y docker.io kubeadm kubectl",
      "ufw allow 6443",
      "kubeadm init --token ${local.token} --token-ttl 15m --upload-certs --certificate-key ${var.certificate_key} --apiserver-cert-extra-sans ${linode_nodebalancer.workspace_lb.ipv4} --node-name bootstrap --control-plane-endpoint ${linode_nodebalancer.workspace_lb.ipv4}:6443",
      "sleep 120s",
      "kubectl --kubeconfig /etc/kubernetes/admin.conf config set-cluster kubernetes --server https://${linode_nodebalancer.workspace_lb.ipv4}:6443",
      "curl https://docs.projectcalico.org/manifests/calico.yaml -sO",
      "kubectl apply --kubeconfig /etc/kubernetes/admin.conf -f calico.yaml",
      "kubeadm token create --print-join-command > /root/kubeadmjoin",
      "truncate -s -1 /root/kubeadmjoin"
    ]
  }
  depends_on = [
    linode_nodebalancer_node.bootstrap_lb_node
  ]
}


data "remote_file" "kubeadmjoin" {
  conn {
    host        = linode_instance.bootstrap.ip_address
    port        = 22
    user        = "root"
    private_key = var.ssh_private_key
  }

  path = "/root/kubeadmjoin"

  depends_on = [
    null_resource.bootstrap_config
  ]
}

resource "linode_nodebalancer_node" "master_lb_node" {
  count           = local.masters
  nodebalancer_id = linode_nodebalancer.workspace_lb.id
  config_id       = linode_nodebalancer_config.workspace_lb-kubectl.id
  address         = "${linode_instance.master[count.index].private_ip_address}:6443"
  label           = local.session_name
  weight          = 100
}

resource "linode_stackscript" "master_stackscript" {
  count       = local.masters
  label       = "master-${count.index}"
  description = "HA kubeadm master node boot script"
  script = templatefile("${path.module}/master_stackscriptsetup.sh",
    {
      cluster_ip   = linode_nodebalancer.workspace_lb.ipv4,
      name         = "master-${count.index}",
      join_command = data.remote_file.kubeadmjoin.content
      cert_key     = var.certificate_key
    }
  )
  images   = ["linode/ubuntu20.04", "linode/ubuntu21.10"]
  rev_note = "initial terraform version"
}

resource "linode_instance" "master" {
  count  = local.masters
  label  = "master-${count.index}"
  region = var.region
  type   = "g6-standard-4"

  disk {
    label           = "ubuntu21.10"
    size            = 30000
    filesystem      = "ext4"
    image           = "linode/ubuntu21.10"
    authorized_keys = [var.ssh_pub_key]
    root_pass       = random_password.random_pass.result
    stackscript_id  = linode_stackscript.master_stackscript[count.index].id
  }

  config {
    label  = "04config"
    kernel = "linode/grub2"
    devices {
      sda {
        disk_label = "ubuntu21.10"
      }
    }
    root_device = "/dev/sda"
  }
  boot_config_label = "04config"

  private_ip = true

  depends_on = [
    linode_instance.bootstrap,
    null_resource.bootstrap_config
  ]
}


resource "linode_stackscript" "worker_stackscript" {
  count       = local.workers
  label       = "worker-${count.index}"
  description = "Kubeadm worker node boot script"
  images      = ["linode/ubuntu20.04", "linode/ubuntu21.10"]
  rev_note    = "initial terraform version"

  script = templatefile("${path.module}/worker_stackscriptsetup.sh",
    {
      cluster_ip   = linode_nodebalancer.workspace_lb.ipv4,
      name         = "worker-${count.index}",
      join_command = data.remote_file.kubeadmjoin.content
    }
  )
}

resource "linode_instance" "worker" {
  count  = local.workers
  label  = "worker-${count.index}"
  region = var.region
  type   = "g6-standard-4"

  disk {
    label           = "ubuntu21.10"
    size            = 30000
    filesystem      = "ext4"
    image           = "linode/ubuntu21.10"
    authorized_keys = [var.ssh_pub_key]
    root_pass       = random_password.random_pass.result
    stackscript_id  = linode_stackscript.worker_stackscript[count.index].id
  }

  config {
    label  = "04config"
    kernel = "linode/grub2"
    devices {
      sda {
        disk_label = "ubuntu21.10"
      }
    }
    root_device = "/dev/sda"
  }
  boot_config_label = "04config"

  private_ip = true

  depends_on = [
    linode_instance.master
  ]
}

