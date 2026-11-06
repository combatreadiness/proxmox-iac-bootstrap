#!/usr/bin/env bash
# =============================================================
# pve-facts.sh — Tell an environment's management node what this host looks like
#   Writes ~/.config/<env>/host.yml inside the management LXC:
#     proxmox: node name, storage
#     images:  image name -> where it lives on this host
#              (LXC template file, VM template ID)
#   Node files ask for an image by name (image: debian-12);
#   OpenTofu looks the name up here.
#
# Run on : Proxmox host shell (as root), via `dsoadm facts [--env NAME]`
#          (also run at the end of `dsoadm init` and `dsoadm template`)
# Re-run : Safe; the file is rewritten.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bootstrap/lib.sh
. "${SCRIPT_DIR}/lib.sh"

select_env
apply_defaults
FACTS_PATH="/root/.config/${PROJECT_ID}/host.yml"
VM_TEMPLATE="$(state_list vm | head -n1)"

[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pct >/dev/null || die "This script must run on a Proxmox VE host."
pct status "$CTID" 2>/dev/null | grep -q running || die "Management container ${CTID} (environment ${ENV_NAME}) is not running."

# ---------- Collect ----------
NODE="$(hostname)"

# LXC image: newest Debian standard template on the template storage
LXC_IMAGE="debian-${DEBIAN_VERSION}"
LXC_TEMPLATE="$(pveam list "$TMPL_STORAGE" 2>/dev/null \
  | awk -v want="debian-${DEBIAN_VERSION}-standard_" 'index($1, want) {print $1}' \
  | sort -V | tail -n 1)"
[[ -n "$LXC_TEMPLATE" ]] || die "No debian-${DEBIAN_VERSION}-standard template on '${TMPL_STORAGE}'. Run: dsoadm init --env ${ENV_NAME}"

# VM image: this environment's cloud-init template, if it has one ("debian-12-cloud" -> "debian-12")
VM_IMAGE="${TEMPLATE_NAME%-cloud}"
HAS_VM=0
if [[ -n "$VM_TEMPLATE" ]] && qm status "$VM_TEMPLATE" &>/dev/null; then
  HAS_VM=1
else
  # Optional: only needed for VM guests. Not a problem, so no warning.
  echo -e "  \e[1;33m–\e[0m No VM template yet (optional, for VM guests: dsoadm template --env ${ENV_NAME})"
fi

# ---------- Build the images block (one entry per image name) ----------
IMAGES_BLOCK="  ${LXC_IMAGE}:
    lxc: ${LXC_TEMPLATE}"
if [[ $HAS_VM -eq 1 ]]; then
  if [[ "$VM_IMAGE" == "$LXC_IMAGE" ]]; then
    IMAGES_BLOCK+="
    vm: ${VM_TEMPLATE}"
  else
    IMAGES_BLOCK+="
  ${VM_IMAGE}:
    vm: ${VM_TEMPLATE}"
  fi
fi

# ---------- Write into the management node ----------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<FACTS
# Written by dsoadm (pve-facts.sh) on $(date -u +%Y-%m-%dT%H:%MZ), environment ${ENV_NAME}.
# Facts about the Proxmox host. Do not edit; override in your own config.
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
