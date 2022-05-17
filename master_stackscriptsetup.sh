#!/bin/bash
# Install kubeadm and Docker
apt-get update
apt-get install -y apt-transport-https curl
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y docker.io kubeadm kubectl
hostnamectl set-hostname ${name}

# Run kubeadm
${join_command} --control-plane --certificate-key ${cert_key} --node-name ${name}

kubectl --kubeconfig /etcd/kubernetes/admin.conf config set-cluster kubernetes --server https://${cluster_ip}:6443
