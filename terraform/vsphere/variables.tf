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
  default = false
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
