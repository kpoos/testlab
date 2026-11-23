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

# Check if template already exists
TEMPLATE_INFO=$(timeout 30 govc vm.info "${TEMPLATE_NAME}" 2>/dev/null) || true
if [[ -n "${TEMPLATE_INFO}" && "${TEMPLATE_INFO}" == *"Name: ${TEMPLATE_NAME}"* ]]; then
    if [[ "${FORCE}" == "true" ]]; then
        log_warn "Template '${TEMPLATE_NAME}' already exists. FORCE=true, deleting and recreating..."
        # govc vm.destroy doesn't work on templates. Use govc object.destroy with the
        # managed object reference (MoRef) from govc vm.info -json instead.
        DESTROYED=false

        # Try 1: Destroy by MoRef (most reliable for templates)
        TEMPLATE_MOREF=$(echo "${TEMPLATE_INFO}" | grep -o '"Obj": *"[^"]*"' | head -1 | sed 's/.*"Obj": *"//;s/"$//')
        if [[ -z "${TEMPLATE_MOREF}" ]]; then
            TEMPLATE_MOREF=$(timeout 30 govc vm.info -json "${TEMPLATE_NAME}" 2>/dev/null \
                | grep -o '"Obj": *"[^"]*"' | head -1 | sed 's/.*"Obj": *"//;s/"$//')
        fi
        if [[ -n "${TEMPLATE_MOREF}" ]]; then
            log_info "Found template MoRef ${TEMPLATE_MOREF}, destroying..."
            if timeout 120 govc object.destroy -force "${TEMPLATE_MOREF}"; then
                DESTROYED=true
            fi
        fi

        # Try 2: Destroy by inventory path
        if [[ "${DESTROYED}" != "true" ]]; then
            TEMPLATE_PATH=$(echo "${TEMPLATE_INFO}" | sed -n 's/^[Pp]ath:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
            if [[ -z "${TEMPLATE_PATH}" ]]; then
                TEMPLATE_PATH=$(timeout 30 govc vm.info "${TEMPLATE_NAME}" 2>/dev/null \
                    | sed -n 's/^[Pp]ath:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
            fi
            if [[ -n "${TEMPLATE_PATH}" ]]; then
                log_info "Found template at ${TEMPLATE_PATH}, destroying..."
                if timeout 120 govc object.destroy -force "${TEMPLATE_PATH}"; then
                    DESTROYED=true
                fi
            fi
        fi

        # Try 3: govc vm.destroy as last resort
        if [[ "${DESTROYED}" != "true" ]]; then
            log_warn "Trying govc vm.destroy as fallback..."
            if timeout 120 govc vm.destroy "${TEMPLATE_NAME}"; then
                DESTROYED=true
            fi
        fi

        if [[ "${DESTROYED}" != "true" ]]; then
            log_error "Failed to delete existing template '${TEMPLATE_NAME}'"
            log_info "Please delete it manually and re-run the script."
            exit 1
        fi
        log_info "Deleted existing template '${TEMPLATE_NAME}'"
    else
        log_warn "Template '${TEMPLATE_NAME}' already exists. Skipping creation."
        log_info "To recreate, set FORCE=true or delete the existing template first: govc vm.destroy ${TEMPLATE_NAME}"
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

# Configure VM for cloud-init
log_info "Configuring VM for cloud-init..."

# Determine SSH public key to inject (matches lab.toml [access] private_key_file)
SSH_PUB_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}"
SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE/#\~/$HOME}"
SSH_PUBLIC_KEY=""
if [[ -f "${SSH_PUB_KEY_FILE}" ]]; then
    SSH_PUBLIC_KEY=$(cat "${SSH_PUB_KEY_FILE}")
    log_info "SSH public key found: ${SSH_PUB_KEY_FILE}"
else
    log_warn "SSH public key not found at ${SSH_PUB_KEY_FILE}; password-only auth will be used"
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
  - name: lab
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}
ssh_pwauth: true
disable_root: false
write_files:
  - path: /etc/ssh/sshd_config.d/99-cloud-init-password-auth.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    permissions: '0644'
runcmd:
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
  - path: /etc/ssh/sshd_config.d/99-cloud-init-password-auth.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
    permissions: '0644'
runcmd:
  - systemctl restart sshd || service sshd restart || true
EOF
fi

# Generate cloud-init metadata (required for cloud-init to trigger)
METADATA_FILE="/tmp/${TEMPLATE_NAME}-metadata"
cat > "${METADATA_FILE}" <<EOF
instance-id: ${TEMPLATE_NAME}
local-hostname: ${TEMPLATE_NAME}
EOF

# Encode userdata and metadata as gzip+base64 for guestinfo
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

# Give cloud-init time to complete
log_info "Waiting for cloud-init to complete..."
sleep 30

# Power off before converting to template
log_info "Powering off VM ${TEMPLATE_NAME}..."
govc vm.power -off "${TEMPLATE_NAME}" || true

# Set firmware to EFI (required for modern Ubuntu)
log_info "Setting firmware to EFI..."
govc vm.change -e="firmware=efi" "${TEMPLATE_NAME}"

# Convert to template
log_info "Converting VM to template..."
govc vm.markastemplate "${TEMPLATE_NAME}"

log_info "Template '${TEMPLATE_NAME}' created successfully!"
log_info "You can now use this template in your Terraform configuration."
