output "node_inventory" {
  value = {
    for name, vm in vsphere_virtual_machine.node : name => {
      ip = var.nodes[name].ip != "" ? var.nodes[name].ip : vm.default_ip_address
    }
  }
}
