variable "lab_name" { type = string }
variable "docker_host" { type = string }
variable "subnet" { type = string }

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
