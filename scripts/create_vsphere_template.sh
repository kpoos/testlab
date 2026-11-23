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
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
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
if [[ ! -f "${IMAGE_FILE}" ]]; then
    curl -L -o "${IMAGE_FILE}" "${CLOUD_IMAGE_URL}"
else
    log_info "Image already downloaded: ${IMAGE_FILE}"
fi

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

# Convert qcow2 to VMDK (required for vSphere)
VMDK_FILE="/tmp/${TEMPLATE_NAME}.vmdk"
log_info "Converting qcow2 to VMDK..."
if command -v qemu-img &> /dev/null; then
    qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized "${IMAGE_FILE}" "${VMDK_FILE}"
else
    log_error "qemu-img not found. Please install qemu-utils to convert the image."
    exit 1
fi

# Upload VMDK to vSphere datastore with a temporary name to avoid locking issues
UPLOAD_PATH="${TEMPLATE_NAME}/${TEMPLATE_NAME}-upload.vmdk"
log_info "Uploading VMDK to datastore ${VCENTER_DATASTORE}..."
govc datastore.upload "${VMDK_FILE}" "${UPLOAD_PATH}"

# Copy the uploaded VMDK to release the lock (govc upload leaves file locked)
FINAL_VMDK_PATH="${TEMPLATE_NAME}/${TEMPLATE_NAME}.vmdk"
log_info "Copying VMDK to release lock..."
govc datastore.cp "${UPLOAD_PATH}" "${FINAL_VMDK_PATH}"

# Remove the temporary upload file
govc datastore.rm "${UPLOAD_PATH}"

# Create VM with a small blank disk first
log_info "Creating VM ${TEMPLATE_NAME} with blank disk..."
govc vm.create \
    -on=false \
    -m=2048 \
    -c=2 \
    -g=ubuntu64Guest \
    -disk=10GB \
    -disk.controller=scsi \
    -net="${VCENTER_NETWORK}" \
    -net.adapter=vmxnet3 \
    "${TEMPLATE_NAME}"

# Remove the blank disk
log_info "Removing blank disk..."
govc vm.disk.remove -vm "${TEMPLATE_NAME}" -disk.name "disk-1000-0" || true

# Attach the uploaded VMDK as the primary disk
log_info "Attaching uploaded VMDK..."
govc vm.disk.attach -vm "${TEMPLATE_NAME}" -disk "${FINAL_VMDK_PATH}" -controller scsi -unit 0

# Add CD-ROM for cloud-init
log_info "Adding CD-ROM for cloud-init..."
govc device.cdrom.add -vm "${TEMPLATE_NAME}" -device cdrom-3000

# Configure VM for cloud-init
log_info "Configuring VM for cloud-init..."
govc vm.change \
    -e="disk.EnableUUID=TRUE" \
    -e="guestinfo.metadata.encoding=gzip+base64" \
    -e="guestinfo.userdata.encoding=gzip+base64" \
    "${TEMPLATE_NAME}"

# Set firmware to EFI (required for modern Ubuntu)
log_info "Setting firmware to EFI..."
govc vm.change -e="firmware=efi" "${TEMPLATE_NAME}"

# Convert to template
log_info "Converting VM to template..."
govc vm.markastemplate "${TEMPLATE_NAME}"

log_info "Template '${TEMPLATE_NAME}' created successfully!"
log_info "You can now use this template in your Terraform configuration."
