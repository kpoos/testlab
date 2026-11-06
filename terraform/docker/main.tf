resource "docker_network" "lab" {
  name = "${var.lab_name}-network"

  ipam_config {
    subnet = var.subnet
  }
}

resource "docker_image" "node" {
  for_each = toset([for node in values(var.nodes) : node.os_image])

  name         = each.value
  keep_locally = true
}

resource "docker_container" "node" {
  for_each = var.nodes

  name        = "${var.lab_name}-${each.value.hostname}"
  hostname    = each.value.hostname
  image       = docker_image.node[each.value.os_image].image_id
  must_run    = true
  privileged  = false
  command     = ["sh", "-c", "while true; do sleep 3600; done"]
  memory      = each.value.memory_mb * 1048576
  memory_swap = each.value.memory_mb * 2097152
  cpu_period  = 100000
  cpu_quota   = each.value.cpu * 100000

  networks_advanced {
    name         = docker_network.lab.name
    aliases      = [each.value.hostname]
    ipv4_address = each.value.ip != "" ? each.value.ip : null
  }
}
