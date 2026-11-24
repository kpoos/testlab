#!/bin/bash
# Script to create a vSphere template from Ubuntu cloud image
# Requires: govc (vSphere CLI) - https://github.com/vmware/govmomi/releases

set -euo pipefail

# Configuration - can be overridden via environment variables
VCENTER_SERVER="${VCENTER_SERVER:-vcenter.lan}"
VCENTER_USERNAME="${VCENTER_USERNAME:-administrator@vsphere.local}"
VCENTER_PASSWORD="${VCENTER_PASSWORD:-}"
VCENTER_DATACENTER="${VCENTER_DATACENTER:-Datacenter}"
VCENTER_DATASTORE="${VCENTER_DATASTORE:-datastore1}"
VCENTER_CLUSTER="${VCENTER_CLUSTER:-Cluster}"
VCENTER_NETWORK="${VCENTER_NETWORK:-VM Network}"
TEMPLATE_NAME="${TEMPLATE_NAME:-Ubuntu-24.04}"
FORCE="${FORCE:-false}"
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.ova}"
CLOUD_IMAGE_CHECKSUM="${CLOUD_IMAGE_CHECKSUM:-}"
ALLOW_UNVERIFIED_SSL="${ALLOW_UNVERIFIED_SSL:-true}"

# Action: create (default) or delete
ACTION="${1:-create}"
if [[ "${ACTION}" != "create" && "${ACTION}" != "delete" ]]; then
    echo "Usage: $0 [create|delete]" >&2
    echo "  create  Create the template (default). Set FORCE=true to recreate." >&2
    echo "  delete  Delete the template and its datastore files." >&2
    exit 2
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if govc is installed
if ! command -v govc &> /dev/null; then
    log_error "govc is not installed. Please install it from https://github.com/vmware/govmomi/releases"
    exit 1
fi

# genisoimage is required to build the cloud-init seed ISO (create only)
if [[ "${ACTION}" == "create" ]] && ! command -v genisoimage &> /dev/null; then
    log_error "genisoimage not found. Please install it (package: genisoimage or cdrkit)."
    exit 1
fi

# Check required environment variables
if [[ -z "$VCENTER_PASSWORD" ]]; then
    log_error "VCENTER_PASSWORD environment variable is required"
    exit 1
fi

# Set govc environment variables
export GOVC_URL="https://${VCENTER_USERNAME}:${VCENTER_PASSWORD}@${VCENTER_SERVER}/sdk"
export GOVC_DATACENTER="${VCENTER_DATACENTER}"
export GOVC_DATASTORE="${VCENTER_DATASTORE}"
export GOVC_CLUSTER="${VCENTER_CLUSTER}"
export GOVC_NETWORK="${VCENTER_NETWORK}"
export GOVC_INSECURE="${ALLOW_UNVERIFIED_SSL}"

log_info "Connecting to vCenter: ${VCENTER_SERVER}"
log_info "Datacenter: ${VCENTER_DATACENTER}"
log_info "Datastore: ${VCENTER_DATASTORE}"
log_info "Cluster: ${VCENTER_CLUSTER}"
log_info "Network: ${VCENTER_NETWORK}"
log_info "Template name: ${TEMPLATE_NAME}"

# Test connection
if ! govc about &> /dev/null; then
    log_error "Failed to connect to vCenter. Check credentials and network."
    exit 1
fi
log_info "Connected to vCenter successfully"

# Delete the template. govc vm.destroy doesn't work reliably on templates, so
# try MoRef first, then inventory path, then govc vm.destroy as a fallback.
delete_template() {
    local template_info moref path
    template_info=$(timeout 30 govc vm.info "${TEMPLATE_NAME}" 2>/dev/null) || true
    if [[ -z "${template_info}" || "${template_info}" != *"Name: ${TEMPLATE_NAME}"* ]]; then
        log_warn "Template '${TEMPLATE_NAME}' does not exist; nothing to delete."
        return 0
    fi

    # Try 1: Destroy by MoRef (most reliable for templates)
    moref=$(echo "${template_info}" | grep -o '"Obj": *"[^"]*"' | head -1 | sed 's/.*"Obj": *"//;s/"$//')
    if [[ -z "${moref}" ]]; then
        moref=$(timeout 30 govc vm.info -json "${TEMPLATE_NAME}" 2>/dev/null \
            | grep -o '"Obj": *"[^"]*"' | head -1 | sed 's/.*"Obj": *"//;s/"$//')
    fi
    if [[ -n "${moref}" ]]; then
        log_info "Found template MoRef ${moref}, destroying..."
        if timeout 120 govc object.destroy -force "${moref}"; then
            log_info "Deleted template '${TEMPLATE_NAME}'"
            return 0
        fi
    fi

    # Try 2: Destroy by inventory path
    path=$(echo "${template_info}" | sed -n 's/^[Pp]ath:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
    if [[ -z "${path}" ]]; then
        path=$(timeout 30 govc vm.info "${TEMPLATE_NAME}" 2>/dev/null \
            | sed -n 's/^[Pp]ath:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
    fi
    if [[ -n "${path}" ]]; then
        log_info "Found template at ${path}, destroying..."
        if timeout 120 govc object.destroy -force "${path}"; then
            log_info "Deleted template '${TEMPLATE_NAME}'"
            return 0
        fi
    fi

    # Try 3: govc vm.destroy as last resort
    log_warn "Trying govc vm.destroy as fallback..."
    if timeout 120 govc vm.destroy "${TEMPLATE_NAME}"; then
        log_info "Deleted template '${TEMPLATE_NAME}'"
        return 0
    fi

    log_error "Failed to delete template '${TEMPLATE_NAME}'"
    log_info "Please delete it manually: govc object.destroy <path>"
    return 1
}

# Handle the delete action: delete the template (and its datastore files) and exit
if [[ "${ACTION}" == "delete" ]]; then
    delete_template || exit 1
    # Clean up template files on the datastore (VMDK folder, seed ISO)
    log_info "Cleaning up template files on datastore ${VCENTER_DATASTORE}..."
    govc datastore.rm -f "${TEMPLATE_NAME}" 2>/dev/null \
        || log_warn "No datastore folder found for '${TEMPLATE_NAME}' (already clean)."
    log_info "Template '${TEMPLATE_NAME}' deleted."
    exit 0
fi

# Check if template already exists
TEMPLATE_INFO=$(timeout 30 govc vm.info "${TEMPLATE_NAME}" 2>/dev/null) || true
if [[ -n "${TEMPLATE_INFO}" && "${TEMPLATE_INFO}" == *"Name: ${TEMPLATE_NAME}"* ]]; then
    if [[ "${FORCE}" == "true" ]]; then
        log_warn "Template '${TEMPLATE_NAME}' already exists. FORCE=true, deleting and recreating..."
        delete_template || exit 1
    else
        log_warn "Template '${TEMPLATE_NAME}' already exists. Skipping creation."
        log_info "To recreate, set FORCE=true or delete it: $0 delete"
        exit 0
    fi
fi

# Download cloud image
IMAGE_FILE="/tmp/$(basename ${CLOUD_IMAGE_URL})"
log_info "Downloading cloud image from ${CLOUD_IMAGE_URL}..."
if [[ ! -f "${IMAGE_FILE}" || ! -s "${IMAGE_FILE}" ]]; then
    curl -L -o "${IMAGE_FILE}" "${CLOUD_IMAGE_URL}"
else
    log_info "Image already downloaded: ${IMAGE_FILE}"
fi

# Validate the downloaded file is non-empty
if [[ ! -s "${IMAGE_FILE}" ]]; then
    log_error "Downloaded image is empty or missing: ${IMAGE_FILE}"
    exit 1
fi
log_info "Image ready: ${IMAGE_FILE} ($(du -h "${IMAGE_FILE}" | awk '{print $1}'))"

# Verify checksum if provided
if [[ -n "${CLOUD_IMAGE_CHECKSUM}" ]]; then
    log_info "Verifying checksum..."
    ACTUAL_CHECKSUM=$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')
    if [[ "${ACTUAL_CHECKSUM}" != "${CLOUD_IMAGE_CHECKSUM}" ]]; then
        log_error "Checksum mismatch! Expected: ${CLOUD_IMAGE_CHECKSUM}, Got: ${ACTUAL_CHECKSUM}"
        exit 1
    fi
    log_info "Checksum verified"
fi

# Import OVA directly into vSphere (no qemu-img conversion needed)
# Retry up to 3 times on transient network failures (e.g. "unexpected EOF")
log_info "Importing OVA into vSphere..."
IMPORT_ATTEMPTS=0
IMPORT_SUCCESS=false
while [[ ${IMPORT_ATTEMPTS} -lt 3 ]]; do
    IMPORT_ATTEMPTS=$((IMPORT_ATTEMPTS + 1))
    log_info "Import attempt ${IMPORT_ATTEMPTS}/3..."
    if govc import.ova -ds="${VCENTER_DATASTORE}" -name="${TEMPLATE_NAME}" "${IMAGE_FILE}"; then
        IMPORT_SUCCESS=true
        break
    else
        log_warn "Import attempt ${IMPORT_ATTEMPTS} failed."
        if [[ ${IMPORT_ATTEMPTS} -lt 3 ]]; then
            log_info "Retrying in 10 seconds..."
            sleep 10
        fi
    fi
done

if [[ "${IMPORT_SUCCESS}" != "true" ]]; then
    log_error "Failed to import OVA after 3 attempts."
    exit 1
fi

# Ensure the network adapter is connected. OVA imports can leave the NIC
# disconnected, and clones inherit that state, leaving them unreachable.
# This MUST succeed or every clone will have a disconnected NIC.
log_info "Connecting network adapter..."
NIC_CONNECTED=false
for NIC in $(govc device.ls -vm "${TEMPLATE_NAME}" 2>/dev/null | awk '/^ethernet/ {print $1}'); do
    if govc device.connect -vm "${TEMPLATE_NAME}" "${NIC}"; then
        log_info "Connected ${NIC}"
        NIC_CONNECTED=true
    else
        log_warn "govc device.connect failed for ${NIC}"
    fi
done
if [[ "${NIC_CONNECTED}" != "true" ]]; then
    log_error "Could not connect any network adapter on ${TEMPLATE_NAME}"
    log_error "Clones would inherit a disconnected NIC. Aborting."
    exit 1
fi

# Configure VM for cloud-init
log_info "Configuring VM for cloud-init..."

# Determine SSH public key to inject. Derive it from the SAME private key that
# Ansible uses (lab.toml access.private_key_file) so the injected key always
# matches; fall back to the .pub file if ssh-keygen is unavailable.
SSH_PRIV_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-~/.ssh/id_ed25519}"
SSH_PRIV_KEY_FILE="${SSH_PRIV_KEY_FILE/#\~/$HOME}"
SSH_PUB_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${SSH_PRIV_KEY_FILE}.pub}"
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE/#\~/$HOME}"
SSH_PUBLIC_KEY=""
if [[ -f "${SSH_PRIV_KEY_FILE}" ]] && command -v ssh-keygen &> /dev/null; then
    SSH_PUBLIC_KEY=$(ssh-keygen -y -f "${SSH_PRIV_KEY_FILE}" 2>/dev/null || true)
fi
if [[ -z "${SSH_PUBLIC_KEY}" && -f "${SSH_PUB_KEY_FILE}" ]]; then
    SSH_PUBLIC_KEY=$(cat "${SSH_PUB_KEY_FILE}")
fi
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    KEY_FP=$(echo "${SSH_PUBLIC_KEY}" | ssh-keygen -lf - 2>/dev/null || echo "unknown")
    log_info "SSH public key ready (derived from ${SSH_PRIV_KEY_FILE})"
    log_info "Injected key fingerprint: ${KEY_FP}"
else
    log_warn "No SSH key found; password-only auth will be used"
fi

# Generate cloud-init userdata that sets up the lab user (matching ssh_user in lab.toml)
USERDATA_FILE="/tmp/${TEMPLATE_NAME}-userdata"
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    cat > "${USERDATA_FILE}" <<EOF
#cloud-config
chpasswd:
  list: |
    ubuntu:ubuntu
    lab:lab
  expire: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}
ssh_pwauth: true
disable_root: false
write_files:
  - path: /etc/ssh/sshd_config.d/00-cloud-init-password-auth.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    permissions: '0644'
  - path: /etc/cloud/cloud.cfg.d/99-vsphere.cfg
    content: |
      datasource_list: [ VMware, NoCloud, None ]
    permissions: '0644'
runcmd:
  - apt-get update && apt-get install -y open-vm-tools
  - systemctl restart sshd || service sshd restart || true
EOF
else
    cat > "${USERDATA_FILE}" <<'EOF'
#cloud-config
chpasswd:
  list: |
    ubuntu:ubuntu
    lab:lab
  expire: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: true
disable_root: false
write_files:
  - path: /etc/ssh/sshd_config.d/00-cloud-init-password-auth.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    permissions: '0644'
  - path: /etc/cloud/cloud.cfg.d/99-vsphere.cfg
    content: |
      datasource_list: [ VMware, NoCloud, None ]
    permissions: '0644'
runcmd:
  - apt-get update && apt-get install -y open-vm-tools
  - systemctl restart sshd || service sshd restart || true
EOF
fi

# Generate cloud-init metadata (required for cloud-init to trigger)
METADATA_FILE="/tmp/${TEMPLATE_NAME}-metadata"
cat > "${METADATA_FILE}" <<EOF
instance-id: ${TEMPLATE_NAME}
local-hostname: ${TEMPLATE_NAME}
EOF

# Build a NoCloud seed ISO (user-data + meta-data). Ubuntu cloud images only
# enable the NoCloud/OVF datasources by default; the guestinfo.* VMware
# datasource is NOT enabled, so delivering config via guestinfo alone never
# runs cloud-init. The seed ISO is the reliable delivery method.
log_info "Building cloud-init seed ISO..."
SEED_DIR="/tmp/${TEMPLATE_NAME}-seed"
rm -rf "${SEED_DIR}"
mkdir -p "${SEED_DIR}"
cp "${USERDATA_FILE}" "${SEED_DIR}/user-data"
cp "${METADATA_FILE}" "${SEED_DIR}/meta-data"
SEED_ISO="/tmp/${TEMPLATE_NAME}-seed.iso"
# Files must be at the ISO root for NoCloud detection, so build from inside SEED_DIR
( cd "${SEED_DIR}" && genisoimage -output "${SEED_ISO}" -volid cidata -joliet -rock \
    user-data meta-data > /dev/null 2>&1 )

# Upload seed ISO to the datastore and insert it into the VM's CD-ROM.
# The OVA's CD-ROM has AutomaticAllocation=false, so it must be explicitly
# connected for cloud-init to read the seed ISO at boot.
log_info "Uploading seed ISO to datastore..."
govc datastore.upload "${SEED_ISO}" "${TEMPLATE_NAME}/seed.iso"

# Ensure a CD-ROM device exists (add one if the OVA lacks it)
if ! govc device.ls -vm "${TEMPLATE_NAME}" 2>/dev/null | grep -q "cdrom-"; then
    log_info "No CD-ROM found; adding one..."
    govc device.cdrom.add -vm "${TEMPLATE_NAME}" > /dev/null
fi

log_info "Inserting seed ISO into CD-ROM..."
govc device.cdrom.insert -vm "${TEMPLATE_NAME}" "${TEMPLATE_NAME}/seed.iso"

# Connect the CD-ROM so it is readable at power-on. This MUST succeed —
# if the CD-ROM is not connected, cloud-init never sees the seed ISO and
# the template ends up with no users/keys/passwords.
log_info "Connecting CD-ROM..."
CDROM_CONNECTED=false
for CDR in $(govc device.ls -vm "${TEMPLATE_NAME}" 2>/dev/null | awk '/^cdrom/ {print $1}'); do
    if govc device.connect -vm "${TEMPLATE_NAME}" "${CDR}"; then
        log_info "Connected ${CDR}"
        CDROM_CONNECTED=true
    else
        log_warn "govc device.connect failed for ${CDR}"
    fi
done
if [[ "${CDROM_CONNECTED}" != "true" ]]; then
    log_error "Could not connect the CD-ROM — cloud-init cannot read the seed ISO."
    log_error "Aborting."
    exit 1
fi

# Ensure the network adapter is connected before boot (clones inherit this state)
log_info "Connecting network adapter..."
govc device.connect -vm "${TEMPLATE_NAME}" ethernet-* || true

# Also set guestinfo.* as a fallback datasource (harmless if unused)
USERDATA_B64=$(gzip -c "${USERDATA_FILE}" | base64 -w0)
METADATA_B64=$(gzip -c "${METADATA_FILE}" | base64 -w0)
govc vm.change \
    -e="disk.EnableUUID=TRUE" \
    -e="guestinfo.metadata.encoding=gzip+base64" \
    -e="guestinfo.metadata=${METADATA_B64}" \
    -e="guestinfo.userdata.encoding=gzip+base64" \
    -e="guestinfo.userdata=${USERDATA_B64}" \
    "${TEMPLATE_NAME}"

# Power on the VM so cloud-init can run on first boot
log_info "Powering on VM ${TEMPLATE_NAME} for cloud-init..."
govc vm.power -on "${TEMPLATE_NAME}"

# Wait for VM to get an IP (cloud-init needs network to complete)
log_info "Waiting for VM to obtain an IP address..."
VM_IP=""
for i in $(seq 1 60); do
    VM_IP=$(govc vm.ip "${TEMPLATE_NAME}" 2>/dev/null | head -1 || true)
    if [[ -n "${VM_IP}" ]]; then
        break
    fi
    sleep 5
done

if [[ -z "${VM_IP}" ]]; then
    log_warn "VM did not obtain an IP address; proceeding anyway."
else
    log_info "VM IP: ${VM_IP}"
fi

# Confirm the CD-ROM stayed connected after power-on (vCenter can reset it)
log_info "Checking CD-ROM state after boot..."
govc device.info -vm "${TEMPLATE_NAME}" cdrom-* 2>/dev/null | grep -iE "StartConnected|Connected" | sed 's/^/    /' || true

# --- Direct configuration via VMware Tools ---
# The base OVA ships with open-vm-tools enabled, so guest.run works from first
# boot. Configure users/keys/passwords directly instead of relying solely on
# cloud-init (which has proven unreliable across datasource/CD-ROM issues).
log_info "Waiting for VMware Tools..."
TOOLS_OK=false
for i in $(seq 1 36); do
    if govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
            echo tools-ok 2>/dev/null | grep -q "tools-ok"; then
        TOOLS_OK=true
        break
    fi
    sleep 5
done
if [[ "${TOOLS_OK}" != "true" ]]; then
    log_error "VMware Tools not responding — cannot configure the VM directly."
    log_error "Check the VM console in vSphere."
    exit 1
fi
log_info "VMware Tools is responding"

log_info "Configuring users, passwords and SSH directly in the guest..."
# Create lab user (ubuntu user already exists in the cloud image)
govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
    sudo useradd -m -s /bin/bash -G sudo lab 2>/dev/null || true

# Set passwords (ubuntu + lab)
govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
    sudo sh -c "echo 'ubuntu:ubuntu' | chpasswd && echo 'lab:lab' | chpasswd"

# Enable password + keyboard-interactive auth (overrides 60-cloudimg-settings.conf
# which sets PasswordAuthentication no; 00- prefix wins first-match)
govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
    sudo sh -c "mkdir -p /etc/ssh/sshd_config.d && printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/00-lab-password-auth.conf"

# Inject SSH public keys for lab and ubuntu
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    for KEY_USER in lab ubuntu; do
        govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
            sudo sh -c "mkdir -p /home/${KEY_USER}/.ssh && chmod 700 /home/${KEY_USER}/.ssh && \
                grep -qF '${SSH_PUBLIC_KEY}' /home/${KEY_USER}/.ssh/authorized_keys 2>/dev/null || \
                echo '${SSH_PUBLIC_KEY}' >> /home/${KEY_USER}/.ssh/authorized_keys && \
                chmod 600 /home/${KEY_USER}/.ssh/authorized_keys && \
                chown -R ${KEY_USER}:${KEY_USER} /home/${KEY_USER}/.ssh"
        log_info "Injected SSH key for user '${KEY_USER}'"
    done
fi

# Restart sshd to apply config
govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
    sudo systemctl restart ssh || sudo service ssh restart || true

# Wait for cloud-init to actually finish (poll status instead of a fixed sleep).
log_info "Waiting for cloud-init to complete..."
CLOUD_INIT_DONE=false
for i in $(seq 1 60); do
    # Prefer SSH (works without VMware Tools once cloud-init created the key)
    CI_STATUS=""
    if [[ -n "${VM_IP}" && -f "${SSH_PRIV_KEY_FILE}" ]]; then
        CI_STATUS=$(ssh -i "${SSH_PRIV_KEY_FILE}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
            "lab@${VM_IP}" "cloud-init status 2>/dev/null" 2>/dev/null || true)
    fi
    # Fallback: VMware Tools guest.run (available once open-vm-tools installed)
    if [[ -z "${CI_STATUS}" ]]; then
        CI_STATUS=$(govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
            cloud-init status 2>/dev/null || true)
    fi
    if [[ "${CI_STATUS}" == *"status: done"* ]]; then
        CLOUD_INIT_DONE=true
        log_info "cloud-init completed: ${CI_STATUS}"
        break
    fi
    if [[ "${CI_STATUS}" == *"status: error"* ]]; then
        log_warn "cloud-init reported an error: ${CI_STATUS}"
        break
    fi
    sleep 5
done
if [[ "${CLOUD_INIT_DONE}" != "true" ]]; then
    log_warn "cloud-init did not report 'done' within 5 minutes; continuing to verification."
fi

# --- Verification ---
# SSH is the definitive test and works WITHOUT VMware Tools (sshd ships in the
# base image), so test it first; use SSH (not guest.run) for all checks below.
VERIFY_OK=true

if [[ -z "${VM_IP}" ]]; then
    log_error "VM has no IP address — cloud-init/network failed."
    VERIFY_OK=false
fi

# Wait up to 2 minutes for sshd to accept key auth
SSH_READY=false
if [[ -n "${SSH_PUBLIC_KEY}" && -f "${SSH_PRIV_KEY_FILE}" && -n "${VM_IP}" ]]; then
    log_info "Waiting for SSH on ${VM_IP}..."
    for i in $(seq 1 24); do
        if ssh -i "${SSH_PRIV_KEY_FILE}" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 \
                -o BatchMode=yes \
                -o LogLevel=ERROR \
                "lab@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"; then
            SSH_READY=true
            break
        fi
        sleep 5
    done
fi

if [[ "${SSH_READY}" == "true" ]]; then
    log_info "Verified: SSH key login works for 'lab'"

    # Verify ubuntu user key too
    if ssh -i "${SSH_PRIV_KEY_FILE}" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            -o BatchMode=yes -o LogLevel=ERROR \
            "ubuntu@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"; then
        log_info "Verified: SSH key login works for 'ubuntu'"
    else
        log_warn "SSH key login FAILED for 'ubuntu'"
        VERIFY_OK=false
    fi

    # Verify password auth is enabled (try password login as ubuntu)
    if sshpass -p ubuntu ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o LogLevel=ERROR "ubuntu@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"; then
        log_info "Verified: password login works (ubuntu:ubuntu)"
    else
        log_warn "password login test skipped/failed (sshpass may be missing)"
    fi
else
    log_error "SSH key login FAILED on ${VM_IP} — cloud-init likely did not run."
    VERIFY_OK=false
fi

if [[ "${VERIFY_OK}" != "true" ]]; then
    log_error "Verification FAILED — the template would be unusable (SSH would fail)."
    log_error "=== Diagnostics ==="
    # Best-effort diagnostics: guest.run needs VMware Tools (only present if
    # cloud-init ran); password SSH may work if cloud-init partially ran.
    govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
        cloud-init status 2>&1 | sed 's/^/    guest: /' || \
        log_warn "    guest.run unavailable (VMware Tools not installed => cloud-init never ran)"
    if [[ -n "${VM_IP}" ]]; then
        sshpass -p ubuntu ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o LogLevel=ERROR "ubuntu@${VM_IP}" \
            "cloud-init status; ls -la /home/lab/.ssh /home/ubuntu/.ssh 2>&1; ls /etc/ssh/sshd_config.d/" \
            2>&1 | sed 's/^/    ssh: /' || true
    fi
    log_error "Seed ISO still inserted for debugging: ${TEMPLATE_NAME}/seed.iso"
    log_error "Aborting before converting to template."
    exit 1
fi

# Reset cloud-init state so clones re-run cloud-init on their first boot
# (picks up per-clone guestinfo hostname/metadata from Terraform).
log_info "Cleaning cloud-init state for clone re-run..."
govc guest.run -vm "${TEMPLATE_NAME}" -l "ubuntu:ubuntu" -- \
    cloud-init clean --logs 2>/dev/null \
    || log_warn "cloud-init clean failed; clones may reuse template instance-id."

# Eject the seed ISO so clones do not inherit it
log_info "Ejecting seed ISO..."
govc device.cdrom.eject -vm "${TEMPLATE_NAME}" 2>/dev/null || true
govc datastore.rm "${TEMPLATE_NAME}/seed.iso" 2>/dev/null || true
rm -rf "${SEED_DIR}" "${SEED_ISO}" 2>/dev/null || true

# Ensure NIC is connected before powering off (clones inherit this state)
log_info "Ensuring network adapter is connected..."
for NIC in $(govc device.ls -vm "${TEMPLATE_NAME}" 2>/dev/null | awk '/^ethernet/ {print $1}'); do
    govc device.connect -vm "${TEMPLATE_NAME}" "${NIC}" || true
done

# Power off before converting to template
log_info "Powering off VM ${TEMPLATE_NAME}..."
govc vm.power -off "${TEMPLATE_NAME}" || true

# Set firmware to EFI (required for modern Ubuntu)
log_info "Setting firmware to EFI..."
govc vm.change -e="firmware=efi" "${TEMPLATE_NAME}"

# Verify NIC connection state before converting to template
log_info "Verifying network adapter connection state..."
NIC_INFO=$(govc device.info -vm "${TEMPLATE_NAME}" ethernet-* 2>/dev/null || true)
if echo "${NIC_INFO}" | grep -qi "StartConnected: true"; then
    log_info "Network adapter StartConnected=true (clones will boot connected)"
else
    log_warn "NIC state not confirmed. device.info output:"
    echo "${NIC_INFO}"
fi

# Convert to template
log_info "Converting VM to template..."
govc vm.markastemplate "${TEMPLATE_NAME}"

log_info "Template '${TEMPLATE_NAME}' created successfully!"
log_info "You can now use this template in your Terraform configuration."
