data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Try to find existing template VM
data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Use the template for all nodes
resource "vsphere_virtual_machine" "node" {
  for_each = var.nodes

  name             = "${var.lab_name}-${each.value.hostname}"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  num_cpus         = each.value.cpu
  memory           = each.value.memory_mb
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  scsi_type        = data.vsphere_virtual_machine.template.scsi_type
  firmware         = data.vsphere_virtual_machine.template.firmware

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = each.value.disk_gb
    thin_provisioned = true
    eagerly_scrub    = false
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = each.value.hostname
        domain    = "local"
      }

      # Only configure static network if IP is provided; otherwise use DHCP
      dynamic "network_interface" {
        for_each = each.value.ip != "" ? [each.value] : []
        content {
          ipv4_address = each.value.ip
          ipv4_netmask = var.network_prefix
        }
      }

      dynamic "ipv4_gateway" {
        for_each = each.value.ip != "" ? [var.gateway] : []
        content {
          value = var.gateway
        }
      }

      dns_server_list = var.dns_servers
    }
  }

  wait_for_guest_net_timeout = 300
  wait_for_guest_ip_timeout  = 300
}

# Output template info for reference
output "template_info" {
  value = {
    name = data.vsphere_virtual_machine.template.name
    id   = data.vsphere_virtual_machine.template.id
  }
}
