variable "lab_name" { type = string }
variable "server" { type = string }
variable "username" { type = string }
variable "password" {
  type      = string
  sensitive = true
}
variable "datacenter" { type = string }
variable "datastore" { type = string }
variable "cluster" { type = string }
variable "network" { type = string }
variable "network_prefix" { type = number }
variable "gateway" { type = string }
variable "dns_servers" { type = list(string) }
variable "allow_unverified_ssl" {
  type    = bool
  default = true
}

# vSphere template configuration
variable "template_name" {
  type        = string
  description = "Name of the vSphere template VM to use for cloning"
  default     = "ubuntu-24.04-template"
}

variable "cloud_image_url" {
  type        = string
  description = "URL to download the Ubuntu cloud image"
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "cloud_image_checksum" {
  type        = string
  description = "SHA256 checksum of the cloud image"
  default     = ""
}

variable "nodes" {
  type = map(object({
    hostname  = string
    role      = string
    ip        = string
    cpu       = number
    memory_mb = number
    disk_gb   = number
    os_image  = string
  }))
}
