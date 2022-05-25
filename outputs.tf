output "lb_address" {
  value = linode_nodebalancer.kubectl_lb.ipv4
}

output "kubeadm_join" {
  value = data.remote_file.kubeadmjoin.content
}
