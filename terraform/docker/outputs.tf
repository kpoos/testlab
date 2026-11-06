output "node_inventory" {
  value = {
    for name, container in docker_container.node : name => {
      ip = var.nodes[name].ip != "" ? var.nodes[name].ip : try(container.network_data[0].ip_address, "")
    }
  }
}
