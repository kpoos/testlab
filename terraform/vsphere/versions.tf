terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "~> 2.8"
    }
  }
}

provider "vsphere" {
  vsphere_server       = var.server
  user                 = var.username
  password             = var.password
  allow_unverified_ssl = var.allow_unverified_ssl
}
