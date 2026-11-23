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
    # NIC connection state is inherited from the template; the template script
    # explicitly connects the adapter before markastemplate so clones come up
    # connected. Do not set mac_address here — vSphere assigns a unique MAC
    # per clone during cloning.
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
    # No customize{} block: VMware Guest Customization (vmware-imc) fails on
    # Ubuntu cloud images. Hostname and network are delivered per-clone via
    # cloud-init guestinfo (see extra_config below).
  }

  # Per-clone cloud-init config: hostname + DHCP. cloud-init reads these
  # guestinfo keys on boot (VMware datasource), replacing Guest Customization.
  extra_config = {
    "guestinfo.metadata" = base64gzip(jsonencode({
      instance-id    = "${var.lab_name}-${each.value.hostname}"
      local-hostname = each.value.hostname
    }))
    "guestinfo.metadata.encoding" = "gzip+base64"
    "guestinfo.userdata" = base64gzip(<<-EOT
      #cloud-config
      hostname: ${each.value.hostname}
      manage_etc_hosts: true
      EOT
    )
    "guestinfo.userdata.encoding" = "gzip+base64"
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
