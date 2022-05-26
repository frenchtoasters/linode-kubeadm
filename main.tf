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
  masters          = 3
  workers          = 3
  pod_network_cidr = "10.0.1.0/16"
  crio_version     = "1.23"
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
    label           = "ubuntu20.04"
    size            = 30000
    filesystem      = "ext4"
    image           = "linode/ubuntu20.04"
    authorized_keys = [var.ssh_pub_key]
    root_pass       = random_password.random_pass.result
  }

  config {
    label  = "04config"
    kernel = "linode/grub2"
    devices {
      sda {
        disk_label = "ubuntu20.04"
      }
    }
    root_device = "/dev/sda"
  }
  boot_config_label = "04config"

  private_ip = true
}

resource "linode_nodebalancer" "kubectl_lb" {
  label                = "kubectl-${local.session_name}-lb"
  region               = var.region
  client_conn_throttle = 2
  tags                 = [local.session_name, "kubectl"]
}

resource "linode_nodebalancer_config" "kubectl_lb_config" {
  nodebalancer_id = linode_nodebalancer.kubectl_lb.id
  port            = 6443
  protocol        = "tcp"
}

resource "linode_nodebalancer_node" "bootstrap_lb_node" {
  nodebalancer_id = linode_nodebalancer.kubectl_lb.id
  config_id       = linode_nodebalancer_config.kubectl_lb_config.id
  address         = "${linode_instance.bootstrap.private_ip_address}:6443"
  label           = "master-bootstrap"
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
      "echo 'deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_20.04/ /'| tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list",
      "echo 'deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${local.crio_version}/xUbuntu_20.04/ /'| tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:${local.crio_version}.list",
      "curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${local.crio_version}/xUbuntu_20.04/Release.key | sudo apt-key add -",
      "curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_20.04/Release.key | sudo apt-key add -",
      "curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -",
      "echo 'deb https://apt.kubernetes.io/ kubernetes-xenial main' >/etc/apt/sources.list.d/kubernetes.list",
      "modprobe overlay",
      "modprobe br_netfilter",
      "touch /etc/sysctl.d/kubernetes.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1' > /etc/sysctl.d/kubernetes.conf",
      "sysctl --system",
      "apt-get -y update",
      "apt-get install -y cri-o cri-o-runc kubeadm kubectl",
      "systemctl daemon-reload",
      "systemctl start crio",
      "systemctl enable crio",
      "ufw allow 6443",
      "hostnamectl set-hostname bootstrap",
      "kubeadm init --token ${local.token} --token-ttl 15m --upload-certs --certificate-key ${var.certificate_key} --apiserver-cert-extra-sans ${linode_nodebalancer.kubectl_lb.ipv4} --node-name bootstrap --control-plane-endpoint ${linode_nodebalancer.kubectl_lb.ipv4}:6443",
      "sleep 120s",
      "kubectl --kubeconfig /etc/kubernetes/admin.conf config set-cluster kubernetes --server https://${linode_nodebalancer.kubectl_lb.ipv4}:6443",
      "curl https://docs.projectcalico.org/manifests/calico.yaml -sO",
      "kubectl apply --kubeconfig /etc/kubernetes/admin.conf -f calico.yaml",
      "kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes bootstrap node-role.kubernetes.io/control-plane:NoSchedule-",
      "kubeadm token create --print-join-command > /root/kubeadmjoin",
      "truncate -s -1 /root/kubeadmjoin"
    ]
  }
  depends_on = [
    linode_nodebalancer_node.bootstrap_lb_node
  ]
}

resource "null_resource" "kubeadm_join" {
  triggers = {
    primary_change = linode_instance.bootstrap.ip_address
    more_masters   = local.masters
    more_workers   = local.workers
  }

  connection {
    host        = linode_instance.bootstrap.ip_address
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "kubeadm init phase upload-certs --upload-certs",
      "kubeadm token create --print-join-command > /root/kubeadmjoin",
      "truncate -s -1 /root/kubeadmjoin"
    ]
  }
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
    null_resource.bootstrap_config,
    null_resource.kubeadm_join
  ]
}

data "remote_file" "admin_kubeconfig" {
  conn {
    host        = linode_instance.bootstrap.ip_address
    port        = 22
    user        = "root"
    private_key = var.ssh_private_key
  }

  path = "/etc/kubernetes/admin.conf"

  depends_on = [
    null_resource.bootstrap_config
  ]
}

resource "linode_nodebalancer_node" "master_lb_node" {
  count           = local.masters
  nodebalancer_id = linode_nodebalancer.kubectl_lb.id
  config_id       = linode_nodebalancer_config.kubectl_lb_config.id
  address         = "${linode_instance.master[count.index].private_ip_address}:6443"
  label           = "master-${count.index}"
}

resource "linode_stackscript" "master_stackscript" {
  count       = local.masters
  label       = "master-${count.index}"
  description = "HA kubeadm master node boot script"
  script = templatefile("${path.module}/master_stackscriptsetup.sh",
    {
      cluster_ip   = linode_nodebalancer.kubectl_lb.ipv4,
      name         = "master-${count.index}",
      join_command = data.remote_file.kubeadmjoin.content
      cert_key     = var.certificate_key
      crio_version = local.crio_version
    }
  )
  images   = ["linode/ubuntu20.04", "linode/ubuntu21.10"]
  rev_note = "initial terraform version"
  depends_on = [
    null_resource.kubeadm_join
  ]
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
      cluster_ip   = linode_nodebalancer.kubectl_lb.ipv4,
      name         = "worker-${count.index}",
      join_command = data.remote_file.kubeadmjoin.content
      crio_version = local.crio_version
    }
  )
  depends_on = [
    null_resource.kubeadm_join
  ]

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

