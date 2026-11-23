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

# Use existing template VM
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
    # Generate a unique MAC address per clone so DHCP assigns distinct IPs.
    # All clones inherit the template's MAC by default, causing duplicate IPs.
    mac_address = "02:50:56:${format("%02x", index(keys(var.nodes), each.key) + 1)}:${format("%02x", index(keys(var.nodes), each.key) + 1)}:${format("%02x", index(keys(var.nodes), each.key) + 1)}"
  }

  disk {
    label            = "disk0"
    size             = max(each.value.disk_gb, 50)
    thin_provisioned = true
    eagerly_scrub    = false
  }

  # CD-ROM required for VMware Guest Customization (customize block delivers
  # vApp properties via a virtual CD-ROM device).
  cdrom {
    client_device = true
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = each.value.hostname
        domain    = "local"
      }

      # DHCP network settings for guest customization
      network_interface {
        ipv4_address = null
        ipv4_netmask = null
      }
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
