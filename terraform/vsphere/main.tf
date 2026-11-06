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

data "vsphere_virtual_machine" "template" {
  for_each      = var.nodes
  name          = each.value.os_image
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "node" {
  for_each = var.nodes

  name             = "${var.lab_name}-${each.value.hostname}"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id
  num_cpus         = each.value.cpu
  memory           = each.value.memory_mb
  guest_id         = data.vsphere_virtual_machine.template[each.key].guest_id
  scsi_type        = data.vsphere_virtual_machine.template[each.key].scsi_type

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template[each.key].network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = each.value.disk_gb
    thin_provisioned = true
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template[each.key].id
    linked_clone  = false

    customize {
      linux_options {
        host_name = each.value.hostname
        domain    = "local"
      }

      network_interface {
        ipv4_address = each.value.ip != "" ? each.value.ip : "0.0.0.0"
        ipv4_netmask = each.value.ip != "" ? var.network_prefix : 0
      }

      ipv4_gateway    = each.value.ip != "" ? var.gateway : null
      dns_server_list = var.dns_servers
    }
  }

  wait_for_guest_net_timeout = 5
  wait_for_guest_ip_timeout  = 5
}
