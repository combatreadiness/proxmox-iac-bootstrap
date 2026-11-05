#!/usr/bin/env bash
# =============================================================
# pve-facts.sh — Tell the management node what this host looks like
#   Writes ~/.config/<project>/host.yml inside the management LXC:
#     proxmox: node name, storage
#     images:  image name -> where it lives on this host
#              (LXC template file, VM template ID)
#   Node files ask for an image by name (image: debian-12);
#   OpenTofu looks the name up here. config.yml in the repo still wins.
#
# Run on : Proxmox host shell (as root), via `dsoadm facts`
#          (also run at the end of `dsoadm init` and `dsoadm template`)
# Re-run : Safe; the file is rewritten.
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

CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/bootstrap.env}"
load_config "$CONFIG_FILE"

# ---------- Settings (same names as pve-host.sh / pve-template.sh) ----------
PROJECT_ID="${PROJECT_ID:-lab}"
CTID="${CTID:-200}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
TMPL_STORAGE="${TMPL_STORAGE:-local}"
DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-cloud}"
FACTS_PATH="/root/.config/${PROJECT_ID}/host.yml"

[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pct >/dev/null || die "This script must run on a Proxmox VE host."
pct status "$CTID" 2>/dev/null | grep -q running || die "Management container ${CTID} is not running."

# ---------- Collect ----------
NODE="$(hostname)"

# LXC image: newest Debian standard template on the template storage
LXC_IMAGE="debian-${DEBIAN_VERSION}"
LXC_TEMPLATE="$(pveam list "$TMPL_STORAGE" 2>/dev/null \
  | awk -v want="debian-${DEBIAN_VERSION}-standard_" 'index($1, want) {print $1}' \
  | sort -V | tail -n 1)"
[[ -n "$LXC_TEMPLATE" ]] || die "No debian-${DEBIAN_VERSION}-standard template on '${TMPL_STORAGE}'. Run: dsoadm init"

# VM image: the cloud-init template, named after it ("debian-12-cloud" -> "debian-12")
VM_IMAGE="${TEMPLATE_NAME%-cloud}"
HAS_VM=0
if qm status "$TEMPLATE_VMID" &>/dev/null; then
  existing=$(qm config "$TEMPLATE_VMID" | awk '/^name:/ {print $2}')
  if [[ "$existing" == "$TEMPLATE_NAME" ]]; then
    HAS_VM=1
  else
    warn "VMID ${TEMPLATE_VMID} is '${existing}', not '${TEMPLATE_NAME}' -> not listed as an image"
  fi
else
  # Optional: only needed for VM guests. Not a problem, so no warning.
  echo -e "  \e[1;33m–\e[0m No VM template yet (optional, for VM guests: dsoadm template)"
fi

# ---------- Build the images block (one entry per image name) ----------
IMAGES_BLOCK="  ${LXC_IMAGE}:
    lxc: ${LXC_TEMPLATE}"
if [[ $HAS_VM -eq 1 ]]; then
  if [[ "$VM_IMAGE" == "$LXC_IMAGE" ]]; then
    IMAGES_BLOCK+="
    vm: ${TEMPLATE_VMID}"
  else
    IMAGES_BLOCK+="
  ${VM_IMAGE}:
    vm: ${TEMPLATE_VMID}"
  fi
fi

# ---------- Write into the management node ----------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<FACTS
# Written by dsoadm (pve-facts.sh) on $(date -u +%Y-%m-%dT%H:%MZ).
# Facts about the Proxmox host. Do not edit; override in the repo's config.yml.
proxmox:
  node: ${NODE}
  storage: ${CT_STORAGE}
images:
${IMAGES_BLOCK}
FACTS

pct exec "$CTID" -- install -d -m 700 "/root/.config/${PROJECT_ID}"
pct push "$CTID" "$TMP" "$FACTS_PATH" --perms 600

log "Host facts written to ${FACTS_PATH} in container ${CTID}:"
sed 's/^/    /' "$TMP"
