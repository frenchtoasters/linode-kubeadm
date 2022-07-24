variable "linode_api_token" {
	type = string
	default = ""
}

variable "region" {
	type = string
	default = "us-southeast"
}

source "linode" "master" {
	image             = "linode/ubuntu20.04"
	image_label       = "packer-ubuntu-2004"
	instance_label    = "temp-packer-ubuntu-2004"
	instance_type     = "g6-standard-4"
	linode_token      = "${var.linode_api_token}"
	region            = "${var.region}"
	ssh_username      = "root"
}

build {
	sources = ["source.linode.master"]
	provisioner "shell" {
		script = "./master_stackscriptsetup.sh"
	}
}


