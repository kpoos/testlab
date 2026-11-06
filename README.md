# Automated Test Lab Provisioner

Terraform provisions the machines, and Ansible optionally configures the selected environment. All settings are defined in one TOML file.

## Supported backends and environments

| Backend | Environments | Notes |
| --- | --- | --- |
| libvirt | `vm`, `docker`, `swarm`, `kubernetes` | Linux VMs booted from cloud images. Kubernetes also creates a dedicated HAProxy VM. |
| vSphere/vCenter | `vm`, `docker`, `swarm`, `kubernetes` | Requires a Linux VM template, vSphere guest customization, and working VMware Tools. Kubernetes also creates a dedicated HAProxy VM. |
| Local Docker | `vm`, `docker` | These are containers, not virtual machines. The Docker backend does not support Kubernetes or Swarm. Docker does not provide a portable per-container disk quota. |

`vm` only starts the machines. `docker` installs and starts Docker Engine. `swarm` initializes one `master` and joins the `worker` machines. `kubernetes` creates a dedicated HAProxy VM, installs a K3s server and agents, and routes Kubernetes API traffic through HAProxy on port 6443. This balances the control-plane API endpoint; it does not configure ingress or load-balance application traffic. The load balancer is a single point of failure and is not highly available. The Docker backend does not support Kubernetes. Cluster setups require Debian-family guests for Docker, Swarm, and the HAProxy VM. K3s also supports other Linux distributions.

## Prerequisites

- Python 3.11 or newer
- Terraform 1.5 or newer
- Ansible (`ansible-playbook`) to configure libvirt/vSphere environments
- Access required by the selected Terraform provider: a libvirt URI, vCenter credentials, or Docker socket
- For libvirt: a downloaded cloud-init-compatible qcow2 image, an existing storage pool, and a network
- For vSphere: a cloneable Linux template, datacenter, cluster, datastore, and network

## Usage

```sh
cp lab.toml.example lab.toml
# Edit the backend and node settings in lab.toml.
python3 scripts/lab.py validate -c lab.toml
python3 scripts/lab.py plan -c lab.toml
python3 scripts/lab.py up -c lab.toml
python3 scripts/lab.py down -c lab.toml
```

`up` applies the Terraform configuration and then runs the Ansible playbook, except when using the Docker backend or the `vm` environment. If configuration is interrupted, run `up` again to continue. `down` destroys machines and containers managed by Terraform.

### Configuration

`lab.toml.example` contains a two-machine example. Each `[[nodes]]` entry supports:

- `name` and `hostname`
- `role`: `master`, `worker`, or `standalone`
- `ip`: `dhcp`/`dynamic` or a static IPv4 address
- `cpu`, `memory_mb`, and `disk_gb`
- `os_image`: a libvirt cloud-image path, vSphere template name, or Docker image name

For Kubernetes, `[load_balancer]` configures the additional HAProxy VM. It supports `name`, `hostname`, `ip`, `cpu`, `memory_mb`, `disk_gb`, and `os_image`. The defaults are `load-balancer`, `haproxy`, `dhcp`, 1 CPU, 1024 MB RAM, and 10 GB disk. If `os_image` is omitted, the master node's image/template is used.

For static VM addresses, set `network_prefix`, `gateway`, and, if needed, `dns_servers` in `[backend]`. On libvirt, `network_interface` must match the interface name used by the guest cloud image. For DHCP addresses, the VM network must provide a lease that Terraform/libvirt can discover.

For libvirt bootstrap, cloud-init installs the key from `access.public_key_file` on the guest; Ansible uses the key at `access.private_key_file`. For vSphere templates, preconfigure the SSH user and public key in the template.

Do not store vCenter credentials in the TOML file. Pass them through environment variables:

```sh
export TF_VAR_username='user@vsphere.local'
export TF_VAR_password='...'
```

## Limitations

- Docker-backend containers do not provide VM-level kernel isolation, SSH access, or a portable disk-size limit. The `cpu` and `memory_mb` resource limits are applied.
- For static vSphere addresses, the IP must be available and the network prefix and gateway must be correct. VMware Tools must be installed and enabled in the template.
- `swarm` and `kubernetes` create a simple single-master test cluster. Firewall and network rules are the responsibility of the user's environment.
- Terraform state is local. Do not run concurrent operations from the same working directory with the same lab name. Configure remote state for production or shared use.
