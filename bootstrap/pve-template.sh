#!/usr/bin/env bash
# =============================================================
# pve-template.sh — Build a cloud-init VM template for OpenTofu to clone
#   1) Create the template pool and give the API account clone-only access
#   2) Download the Debian cloud image and verify its checksum
#   3) Create the VM, import the disk, attach cloud-init, convert to template
#   4) Record which image was used (source, SHA512, date) in the description
#
# Run on : Proxmox host shell (as root), usually via `dsoadm template`
# Re-run : Safe; an existing template with the same name is kept.
#
# Image version:
#   Default is ".../bookworm/latest". The template is built once and every VM
#   is cloned from it, so your lab stays consistent. To pin an exact build for
#   reproducibility, set IMAGE_BASE_URL in bootstrap.env to a dated folder, e.g.
#   IMAGE_BASE_URL=https://cloud.debian.org/images/cloud/bookworm/20261020-XXXX
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log()  { echo -e "  \e[1;32m✔\e[0m $*"; }
warn() { echo -e "  \e[1;33m⚠\e[0m $*"; }
die()  { echo -e "  \e[1;31m✖\e[0m $*" >&2; exit 1; }

# Read KEY=VALUE lines without executing the file (same rules as pve-host.sh)
load_config() {
  local file="$1" key value
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key//[[:space:]]/}"
    if [[ -z "$key" || "$key" == \#* ]]; then continue; fi
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then continue; fi
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "${!key+x}" ]]; then printf -v "$key" '%s' "$value"; fi
  done < "$file"
}

json_has() {
  python3 -c '
import json, sys
key, val = sys.argv[1], sys.argv[2]
sys.exit(0 if any(d.get(key) == val for d in json.load(sys.stdin)) else 1)' "$1" "$2"
}

json_get() {
  python3 -c '
import json, sys
key, val, field = sys.argv[1:4]
for d in json.load(sys.stdin):
    if d.get(key) == val:
        print(d.get(field, "") or ""); break' "$1" "$2" "$3"
}

CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/bootstrap.env}"
load_config "$CONFIG_FILE"

# ---------- Settings ----------
PROJECT_ID="${PROJECT_ID:-lab}"
POOL_PREFIX="${POOL_PREFIX-lab}"
TF_USER="${TF_USER:-terraform@pve}"
TF_CLONE_ROLE="${TF_CLONE_ROLE:-TerraformClone}"   # Clone and read the template, nothing else

TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-cloud}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-${CT_STORAGE:-local-lvm}}"
TEMPLATE_BRIDGE="${TEMPLATE_BRIDGE:-${SDN_VNET:-lmgmt}}"   # Replaced by OpenTofu on clone
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest}"
IMAGE_FILE="${IMAGE_FILE:-debian-12-genericcloud-amd64.qcow2}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/cache}"

PROJECT_MARKER="managed-by:${PROJECT_ID}"
if [[ -n "$POOL_PREFIX" ]]; then TEMPLATE_POOL="${POOL_PREFIX}-templates"; else TEMPLATE_POOL="templates"; fi

# =============================================================
# 0. Pre-flight
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v qm >/dev/null || die "This script must run on a Proxmox VE host."
log "Template: VMID ${TEMPLATE_VMID} (${TEMPLATE_NAME}) on ${TEMPLATE_STORAGE}, pool ${TEMPLATE_POOL}"

# =============================================================
# 1. Pool and clone-only permission
# =============================================================
if pvesh get /pools --output-format json | json_has poolid "$TEMPLATE_POOL"; then
  comment=$(pvesh get /pools --output-format json | json_get poolid "$TEMPLATE_POOL" comment)
  [[ "$comment" == *"$PROJECT_MARKER"* ]] \
    || die "Pool '${TEMPLATE_POOL}' exists but was not created by this project."
  log "Pool '${TEMPLATE_POOL}' already exists -> skipping"
else
  log "Creating pool '${TEMPLATE_POOL}'"
  pvesh create /pools --poolid "$TEMPLATE_POOL" --comment "VM templates [${PROJECT_MARKER}]"
fi

if pveum role list --output-format json | json_has roleid "$TF_CLONE_ROLE"; then
  pveum role modify "$TF_CLONE_ROLE" --privs "VM.Clone VM.Audit"
else
  log "Creating role '${TF_CLONE_ROLE}' (VM.Clone, VM.Audit)"
  pveum role add "$TF_CLONE_ROLE" --privs "VM.Clone VM.Audit"
fi
log "Granting ${TF_CLONE_ROLE} on /pool/${TEMPLATE_POOL}"
pveum acl modify "/pool/${TEMPLATE_POOL}" --users "$TF_USER" --roles "$TF_CLONE_ROLE"

# =============================================================
# 2. Existing template?
# =============================================================
if qm status "$TEMPLATE_VMID" &>/dev/null; then
  existing=$(qm config "$TEMPLATE_VMID" | awk '/^name:/ {print $2}')
  [[ "$existing" == "$TEMPLATE_NAME" ]] \
    || die "VMID ${TEMPLATE_VMID} is used by '${existing}'. Set TEMPLATE_VMID to a free ID."
  log "Template ${TEMPLATE_VMID} (${TEMPLATE_NAME}) already exists -> nothing to do"
  qm config "$TEMPLATE_VMID" | sed -n 's/^description: /    /p' | python3 -c \
    'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()), end="")'
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

# What exactly went into this template (shown in the Proxmox GUI "Notes")
BUILD_DATE="$(date -u +%Y-%m-%d)"
DESCRIPTION="Debian 12 cloud image. Clone source for OpenTofu. Created by dsoadm template.
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
  --ostype l26 \
  --cores 1 --memory 1024 \
  --net0 "virtio,bridge=${TEMPLATE_BRIDGE}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${TEMPLATE_STORAGE}:0,import-from=${IMAGE_PATH},discard=on" \
  --ide2 "${TEMPLATE_STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --serial0 socket --vga serial0 \
  --agent enabled=0 \
  --description "$DESCRIPTION"

log "Converting to template"
qm template "$TEMPLATE_VMID"

log "Done: template ${TEMPLATE_VMID} (${TEMPLATE_NAME}) in pool ${TEMPLATE_POOL}"
