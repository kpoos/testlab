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
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-24.04-template}"
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
if govc vm.info "${TEMPLATE_NAME}" &> /dev/null; then
    log_warn "Template '${TEMPLATE_NAME}' already exists. Skipping creation."
    log_info "To recreate, delete the existing template first: govc vm.destroy ${TEMPLATE_NAME}"
    exit 0
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

# Upload image to vSphere datastore
log_info "Uploading image to datastore ${VCENTER_DATASTORE}..."
govc datastore.upload "${IMAGE_FILE}" "${TEMPLATE_NAME}/$(basename ${IMAGE_FILE})"

# Create VM from uploaded image
log_info "Creating VM ${TEMPLATE_NAME}..."
govc vm.create \
    -on=false \
    -m=2048 \
    -c=2 \
    -g=ubuntu64Guest \
    -disk="${TEMPLATE_NAME}/$(basename ${IMAGE_FILE})" \
    -disk.controller=scsi \
    -net="${VCENTER_NETWORK}" \
    -net.adapter=vmxnet3 \
    "${TEMPLATE_NAME}"

# Configure VM for cloud-init
log_info "Configuring VM for cloud-init..."
govc vm.change \
    -e="disk.EnableUUID=TRUE" \
    -e="guestinfo.metadata.encoding=gzip+base64" \
    -e="guestinfo.userdata.encoding=gzip+base64" \
    "${TEMPLATE_NAME}"

# Convert to template
log_info "Converting VM to template..."
govc vm.markastemplate "${TEMPLATE_NAME}"

log_info "Template '${TEMPLATE_NAME}' created successfully!"
log_info "You can now use this template in your Terraform configuration."
