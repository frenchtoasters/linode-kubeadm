#!/bin/bash
# Install kubeadm and Cri-o
apt-get update
apt-get install -y apt-transport-https curl

echo 'deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_20.04/ /'| tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
echo 'deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${crio_version}/xUbuntu_20.04/ /'| tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:${crio_version}.list
curl -L https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${crio_version}/xUbuntu_20.04/Release.key | sudo apt-key add -
curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_20.04/Release.key | sudo apt-key add -
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo 'deb https://apt.kubernetes.io/ kubernetes-xenial main' >/etc/apt/sources.list.d/kubernetes.list

modprobe overlay
modprobe br_netfilter
touch /etc/sysctl.d/kubernetes.conf

tee <<EOF > /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system
apt-get -y update
apt-get install -y cri-o cri-o-runc kubeadm kubectl
systemctl daemon-reload
systemctl start crio
systemctl enable crio
ufw allow 6443
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y cri-o cri-o-runc kubeadm kubectl
hostnamectl set-hostname ${name}

# Run kubeadm
${join_command} --control-plane --certificate-key ${cert_key} --node-name ${name}

kubectl --kubeconfig /etcd/kubernetes/admin.conf config set-cluster kubernetes --server https://${cluster_ip}:6443
