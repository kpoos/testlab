output "node_inventory" {
  value = {
    for name, domain in libvirt_domain.node : name => {
      ip = var.nodes[name].ip != "" ? var.nodes[name].ip : try(domain.network_interface[0].addresses[0], "")
    }
  }
}
