resource "libvirt_volume" "base" {
  for_each = var.nodes

  name   = "${var.lab_name}-${each.value.hostname}-base.qcow2"
  pool   = var.pool
  source = each.value.os_image
  format = "qcow2"
}

resource "libvirt_volume" "root" {
  for_each = var.nodes

  name           = "${var.lab_name}-${each.value.hostname}.qcow2"
  pool           = var.pool
  base_volume_id = libvirt_volume.base[each.key].id
  size           = each.value.disk_gb * 1073741824
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = var.nodes

  name = "${var.lab_name}-${each.value.hostname}-seed.iso"
  meta_data = yamlencode({
    instance_id    = "${var.lab_name}-${each.value.hostname}"
    local-hostname = each.value.hostname
  })
  user_data = templatefile("${path.module}/cloud_init.yaml.tftpl", {
    hostname       = each.value.hostname
    ssh_user       = var.ssh_user
    ssh_public_key = var.ssh_public_key
  })
  network_config = templatefile("${path.module}/network_config.yaml.tftpl", {
    interface_name = var.network_interface
    ip             = each.value.ip
    prefix         = var.network_prefix
    gateway        = var.gateway
    dns_servers    = var.dns_servers
  })
}

resource "libvirt_domain" "node" {
  for_each = var.nodes

  type      = "kvm"
  name      = "${var.lab_name}-${each.value.hostname}"
  memory    = each.value.memory_mb
  vcpu      = each.value.cpu
  cloudinit = libvirt_cloudinit_disk.node[each.key].id

  disk {
    volume_id = libvirt_volume.root[each.key].id
  }

  network_interface {
    network_name   = var.network
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}
