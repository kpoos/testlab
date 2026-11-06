variable "lab_name" { type = string }
variable "uri" { type = string }
variable "pool" { type = string }
variable "network" { type = string }
variable "network_interface" { type = string }
variable "network_prefix" { type = number }
variable "gateway" { type = string }
variable "dns_servers" { type = list(string) }
variable "ssh_user" { type = string }
variable "ssh_public_key" { type = string }

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
