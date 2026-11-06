#!/usr/bin/env bash
# =============================================================
# pve-template.sh — Cloud-init VM template for OpenTofu to clone (`dsoadm template`)
#   1) Template pool for this environment, API account gets clone-only access
#   2) Download the Debian cloud image and verify its checksum (shared cache)
#   3) Create the VM, import the disk, attach cloud-init, convert to template
#   4) Record which image was used (source, SHA512, date) in the description
# Each environment gets its own template (its own VMID), recorded in its state.
#
# Run on : Proxmox host shell (as root), via `dsoadm template [--env NAME]`
# Re-run : Safe; an existing template of this environment is kept.
#
# Image version:
#   Default is ".../bookworm/latest". To pin an exact build, set IMAGE_BASE_URL
#   to a dated folder, e.g. https://cloud.debian.org/images/cloud/bookworm/20261020-XXXX
# =============================================================
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bootstrap/lib.sh
. "${SCRIPT_DIR}/lib.sh"

select_env
apply_defaults

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$CT_STORAGE}"
TEMPLATE_BRIDGE="${TEMPLATE_BRIDGE:-$SDN_VNET}"   # Replaced by OpenTofu on clone
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest}"
IMAGE_FILE="${IMAGE_FILE:-debian-12-genericcloud-amd64.qcow2}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/cache}"
TEMPLATE_POOL="$(pool_name templates)"

# =============================================================
# 0. Pre-flight
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v qm >/dev/null || die "This script must run on a Proxmox VE host."
[[ -f "$STATE_FILE" ]] || die "Environment '${ENV_NAME}' has not been set up. Run: dsoadm init --env ${ENV_NAME}"

# Which VMID: the one this environment already made, the configured one, or the first free from 9000
EXISTING_VM="$(state_list vm | head -n1)"
if [[ -n "$EXISTING_VM" ]]; then
  TEMPLATE_VMID="$EXISTING_VM"
elif [[ -z "$TEMPLATE_VMID" ]]; then
  TEMPLATE_VMID="$(free_id 9000)"
  set_config "$CONFIG_FILE" TEMPLATE_VMID "$TEMPLATE_VMID"
  log "Picked free VMID ${TEMPLATE_VMID} (saved to ${CONFIG_FILE})"
fi
not_others vm "$TEMPLATE_VMID" "VMID ${TEMPLATE_VMID}"
log "Environment : ${ENV_NAME}"
log "Template    : VMID ${TEMPLATE_VMID} (${TEMPLATE_NAME}) on ${TEMPLATE_STORAGE}, pool ${TEMPLATE_POOL}"

# =============================================================
# 1. Pool and clone-only permission
# =============================================================
if pvesh get /pools --output-format json | json_has poolid "$TEMPLATE_POOL"; then
  comment=$(pvesh get /pools --output-format json | json_get poolid "$TEMPLATE_POOL" comment)
  [[ "$comment" == *"$PROJECT_MARKER"* ]] \
    || die "Pool '${TEMPLATE_POOL}' exists but was not created by environment '${ENV_NAME}'."
  log "Pool '${TEMPLATE_POOL}' already exists -> skipping"
else
  log "Creating pool '${TEMPLATE_POOL}'"
  pvesh create /pools --poolid "$TEMPLATE_POOL" --comment "VM templates [${PROJECT_MARKER}]"
  state_add pool "$TEMPLATE_POOL"
fi

if pveum role list --output-format json | json_has roleid "$TF_CLONE_ROLE"; then
  pveum role modify "$TF_CLONE_ROLE" --privs "VM.Clone VM.Audit"
else
  log "Creating role '${TF_CLONE_ROLE}' (VM.Clone, VM.Audit)"
  pveum role add "$TF_CLONE_ROLE" --privs "VM.Clone VM.Audit"
  state_add role "$TF_CLONE_ROLE"
fi
log "Granting ${TF_CLONE_ROLE} on /pool/${TEMPLATE_POOL}"
pveum acl modify "/pool/${TEMPLATE_POOL}" --users "$TF_USER" --roles "$TF_CLONE_ROLE"

# =============================================================
# 2. Existing template?
# =============================================================
if qm status "$TEMPLATE_VMID" &>/dev/null; then
  existing=$(qm config "$TEMPLATE_VMID" | awk '/^name:/ {print $2}')
  [[ "$existing" == "$TEMPLATE_NAME" ]] \
    || die "VMID ${TEMPLATE_VMID} is used by '${existing}'. Set TEMPLATE_VMID in ${CONFIG_FILE} to a free ID."
  state_has vm "$TEMPLATE_VMID" || die "VMID ${TEMPLATE_VMID} exists but was not created by environment '${ENV_NAME}'."
  log "Template ${TEMPLATE_VMID} (${TEMPLATE_NAME}) already exists -> nothing to do"
  exit 0
fi

# =============================================================
# 3. Download and verify the cloud image
# =============================================================
mkdir -p "$IMAGE_DIR"
IMAGE_PATH="${IMAGE_DIR}/${IMAGE_FILE}"
SUMS_PATH="${IMAGE_DIR}/${IMAGE_FILE}.SHA512SUMS"

log "Fetching checksums from ${IMAGE_BASE_URL}"
curl -fsSL "${IMAGE_BASE_URL}/SHA512SUMS" -o "$SUMS_PATH"
EXPECTED=$(awk -v f="$IMAGE_FILE" '$2 == f {print $1}' "$SUMS_PATH")
[[ -n "$EXPECTED" ]] || die "No checksum for ${IMAGE_FILE} in SHA512SUMS."

if [[ -f "$IMAGE_PATH" ]] && echo "${EXPECTED}  ${IMAGE_PATH}" | sha512sum -c --status; then
  log "Image already downloaded and verified -> skipping download"
else
  log "Downloading ${IMAGE_FILE}"
  curl -fL --progress-bar "${IMAGE_BASE_URL}/${IMAGE_FILE}" -o "${IMAGE_PATH}.part"
  echo "${EXPECTED}  ${IMAGE_PATH}.part" | sha512sum -c --status \
    || { rm -f "${IMAGE_PATH}.part"; die "Checksum mismatch. Download discarded."; }
  mv "${IMAGE_PATH}.part" "$IMAGE_PATH"
  log "Checksum verified"
fi

BUILD_DATE="$(date -u +%Y-%m-%d)"
DESCRIPTION="Debian 12 cloud image. Clone source for OpenTofu, environment ${ENV_NAME}. Created by dsoadm template.
Source: ${IMAGE_BASE_URL}/${IMAGE_FILE}
SHA512: ${EXPECTED:0:16}... (verified)
Built:  ${BUILD_DATE} (UTC)"
log "Image SHA512: ${EXPECTED:0:16}..."

# =============================================================
# 4. Create the VM and convert it to a template
# =============================================================
log "Creating VM ${TEMPLATE_VMID}"
qm create "$TEMPLATE_VMID" \
  --name "$TEMPLATE_NAME" \
  --pool "$TEMPLATE_POOL" \
  --tags "template;bootstrap;env-${ENV_NAME}" \
  --ostype l26 \
  --cores 1 --memory 1024 \
  --net0 "virtio,bridge=${TEMPLATE_BRIDGE}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${TEMPLATE_STORAGE}:0,import-from=${IMAGE_PATH},discard=on" \
  --ide2 "${TEMPLATE_STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket --vga serial0 \
  --agent enabled=0 \
  --description "$DESCRIPTION" 2>&1 | indent
state_add vm "$TEMPLATE_VMID"

log "Converting to template"
qm template "$TEMPLATE_VMID"

log "Done: template ${TEMPLATE_VMID} (${TEMPLATE_NAME}) in pool ${TEMPLATE_POOL}"
