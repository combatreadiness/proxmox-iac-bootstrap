#!/usr/bin/env bash
# =============================================================
# pve-reset.sh — Undo what `dsoadm init` and `dsoadm template` created
#   0) Stop if guests still exist in the operational pools (destroy them first, e.g. `tofu destroy`)
#   1) Destroy the management LXC
#   2) Destroy the VM template
#   3) Remove the project's pools (only if empty and owned by this project)
#   4) Remove the API user (with its tokens and ACLs) and the project's roles
#   5) Optional: remove the management SDN subnet / vnet / zone   -> RESET_SDN=1
#
# Run on : Proxmox host shell (as root), usually via `dsoadm reset`
# Usage  : DRY_RUN=1 ./pve-reset.sh     (show what would be removed)
#          ./pve-reset.sh               (asks for confirmation)
#          RESET_SDN=1 ./pve-reset.sh   (also remove the SDN network)
#          FORCE=1 ./pve-reset.sh       (skip the confirmation prompt)
# Keeps  : Downloaded images and templates on storage (a cache for the next init)
# Safety : Resources not created by this project are never removed.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------- Helpers ----------
log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# Read KEY=VALUE lines from a config file without executing it.
# Variables already set (e.g. passed on the command line) take precedence.
load_config() {
  local file="$1" key value
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key//[[:space:]]/}"
    if [[ -z "$key" || "$key" == \#* ]]; then continue; fi
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "Ignoring invalid line in ${file}: ${key}"
      continue
    fi
    value="${value%%#*}"                        # Strip inline comments
    value="${value#"${value%%[![:space:]]*}"}"  # Trim leading spaces
    value="${value%"${value##*[![:space:]]}"}"  # Trim trailing spaces
    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done < "$file"
}

# pool_name mgmt -> <prefix>-mgmt (or "mgmt" when the prefix is empty)
pool_name() {
  if [[ -n "$POOL_PREFIX" ]]; then echo "${POOL_PREFIX}-$1"; else echo "$1"; fi
}

# <json array> | json_has <key> <value>   -> exit 0 if any item matches
json_has() {
  python3 -c '
import json, sys
key, val = sys.argv[1], sys.argv[2]
sys.exit(0 if any(d.get(key) == val for d in json.load(sys.stdin)) else 1)' "$1" "$2"
}

# <json array> | json_get <key> <value> <field>   -> print field of first match
json_get() {
  python3 -c '
import json, sys
key, val, field = sys.argv[1:4]
for d in json.load(sys.stdin):
    if d.get(key) == val:
        print(d.get(field, "") or "")
        break' "$1" "$2" "$3"
}

# <subnet json array> | subnet_id <cidr>   -> print the subnet ID (e.g. lab-10.73.10.0-24)
subnet_id() {
  python3 -c '
import json, sys
cidr = sys.argv[1]
suffix = cidr.replace("/", "-")
for d in json.load(sys.stdin):
    sid = str(d.get("subnet", ""))
    if d.get("cidr") == cidr or sid.endswith(suffix):
        print(sid)
        break' "$1"
}

# Number of guests in a pool (0 if the pool does not exist)
pool_members() {
  if pvesh get /pools --output-format json | json_has poolid "$1"; then
    pvesh get "/pools/$1" --output-format json \
      | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("members", [])))'
  else
    echo 0
  fi
}

CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/bootstrap.env}"
load_config "$CONFIG_FILE"

# ---------- Settings (same names as pve-host.sh / pve-template.sh) ----------
PROJECT_ID="${PROJECT_ID:-lab}"
SDN_ZONE="${SDN_ZONE:-lab}"
SDN_VNET="${SDN_VNET:-lmgmt}"
SDN_SUBNET="${SDN_SUBNET:-10.73.10.0/24}"
CTID="${CTID:-200}"
CT_HOSTNAME="${CT_HOSTNAME:-iac-mgmt}"
TF_USER="${TF_USER:-terraform@pve}"
TF_ROLE="${TF_ROLE:-TerraformRole}"
TF_SDN_ROLE="${TF_SDN_ROLE:-TerraformSDNApply}"
TF_CLONE_ROLE="${TF_CLONE_ROLE:-TerraformClone}"
POOL_PREFIX="${POOL_PREFIX-lab}"
OP_POOLS="${OP_POOLS:-tools k8s targets}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-cloud}"

DRY_RUN="${DRY_RUN:-0}"
RESET_SDN="${RESET_SDN:-0}"
FORCE="${FORCE:-0}"

PROJECT_MARKER="managed-by:${PROJECT_ID}"
MGMT_POOL="$(pool_name mgmt)"
TEMPLATE_POOL="$(pool_name templates)"
OP_POOL_NAMES=()
for p in $OP_POOLS; do OP_POOL_NAMES+=("$(pool_name "$p")"); done

# Execute a command, or only print it in dry-run mode
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "\e[1;36m[dry-run]\e[0m $*"
  else
    "$@"
  fi
}

# =============================================================
# 0. Pre-flight
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."

# Lab nodes live in the operational pools and are tracked by OpenTofu state on the
# management node. Removing that node first would leave them unmanaged.
NODES_LEFT=0
for p in "${OP_POOL_NAMES[@]}"; do
  n=$(pool_members "$p")
  if [[ "$n" != "0" ]]; then
    warn "Pool '${p}' still has ${n} guest(s)"
    NODES_LEFT=1
  fi
done
if [[ $NODES_LEFT -eq 1 ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "A real reset would stop here. Destroy those guests first (e.g. tofu destroy on the management node)."
  else
    die "Guests still exist in the operational pools. Destroy them first (e.g. tofu destroy on the management node)."
  fi
fi

echo
echo "This will remove:"
echo "  - LXC ${CTID} (${CT_HOSTNAME})"
echo "  - VM template ${TEMPLATE_VMID} (${TEMPLATE_NAME})"
echo "  - Pools ${MGMT_POOL} ${OP_POOL_NAMES[*]} ${TEMPLATE_POOL} (if empty and created by this project)"
echo "  - User ${TF_USER} (with its tokens and ACLs)"
echo "  - Roles ${TF_ROLE}, ${TF_SDN_ROLE}, ${TF_CLONE_ROLE}"
if [[ "$RESET_SDN" == "1" ]]; then
  echo "  - SDN subnet ${SDN_SUBNET}, vnet ${SDN_VNET}, zone ${SDN_ZONE} (if unused)"
fi
echo "Kept: downloaded images and templates on storage (reused by the next init)"
if [[ "$DRY_RUN" == "1" ]]; then echo "  (dry-run: nothing will actually be removed)"; fi
echo

if [[ "$DRY_RUN" != "1" && "$FORCE" != "1" ]]; then
  read -r -p "Type the container hostname '${CT_HOSTNAME}' to confirm: " answer
  [[ "$answer" == "$CT_HOSTNAME" ]] || die "Confirmation did not match. Aborted."
fi

# =============================================================
# 1. Management LXC
# =============================================================
if pct status "$CTID" &>/dev/null; then
  EXISTING_HN=$(pct config "$CTID" | awk '/^hostname:/ {print $2}')
  if [[ "$EXISTING_HN" != "$CT_HOSTNAME" ]]; then
    warn "CTID ${CTID} is '${EXISTING_HN}', not '${CT_HOSTNAME}' -> not touching it"
  else
    if pct status "$CTID" | grep -q running; then
      log "Stopping LXC ${CTID}"
      run pct stop "$CTID"
    fi
    log "Destroying LXC ${CTID} (${CT_HOSTNAME})"
    run pct destroy "$CTID" --purge 1     # --purge also removes it from pools/ACLs/backup jobs
  fi
else
  log "LXC ${CTID} not found -> skipping"
fi

# =============================================================
# 2. VM template
# =============================================================
if qm status "$TEMPLATE_VMID" &>/dev/null; then
  EXISTING_NAME=$(qm config "$TEMPLATE_VMID" | awk '/^name:/ {print $2}')
  if [[ "$EXISTING_NAME" != "$TEMPLATE_NAME" ]]; then
    warn "VMID ${TEMPLATE_VMID} is '${EXISTING_NAME}', not '${TEMPLATE_NAME}' -> not touching it"
  else
    log "Destroying VM template ${TEMPLATE_VMID} (${TEMPLATE_NAME})"
    run qm destroy "$TEMPLATE_VMID" --purge 1
  fi
else
  log "VM template ${TEMPLATE_VMID} not found -> skipping"
fi

# =============================================================
# 3. Pools
# =============================================================
for POOL in "$MGMT_POOL" "${OP_POOL_NAMES[@]}" "$TEMPLATE_POOL"; do
  if ! pvesh get /pools --output-format json | json_has poolid "$POOL"; then
    log "Pool '${POOL}' not found -> skipping"
    continue
  fi
  POOL_COMMENT=$(pvesh get /pools --output-format json | json_get poolid "$POOL" comment)
  if [[ "$POOL_COMMENT" != *"$PROJECT_MARKER"* ]]; then
    warn "Pool '${POOL}' was not created by this project -> not touching it"
    continue
  fi
  MEMBERS=$(pool_members "$POOL")
  if [[ "$MEMBERS" != "0" && "$DRY_RUN" != "1" ]]; then
    warn "Pool '${POOL}' still has ${MEMBERS} member(s) -> not removing"
  else
    log "Removing pool '${POOL}'"
    run pvesh delete "/pools/${POOL}"
  fi
done

# =============================================================
# 4. API user, tokens, roles
# =============================================================
if pveum user list --output-format json | json_has userid "$TF_USER"; then
  log "Removing user '${TF_USER}' (tokens and ACLs included)"
  run pveum user delete "$TF_USER"
else
  log "User '${TF_USER}' not found -> skipping"
fi

for ROLE in "$TF_ROLE" "$TF_SDN_ROLE" "$TF_CLONE_ROLE"; do
  if pveum role list --output-format json | json_has roleid "$ROLE"; then
    log "Removing role '${ROLE}'"
    run pveum role delete "$ROLE"
  else
    log "Role '${ROLE}' not found -> skipping"
  fi
done

# =============================================================
# 5. SDN (only with RESET_SDN=1)
# =============================================================
if [[ "$RESET_SDN" != "1" ]]; then
  log "SDN kept (set RESET_SDN=1 to remove it)"
else
  # Refuse if any other guest is still attached to this vnet
  ATTACHED=$(grep -lE "bridge=${SDN_VNET}([,[:space:]]|$)" \
      /etc/pve/nodes/*/lxc/*.conf /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null \
    | grep -vE "/(${CTID}|${TEMPLATE_VMID})\.conf$" || true)   # Both are removed above
  if [[ -n "$ATTACHED" ]]; then
    warn "Other guests still use '${SDN_VNET}', keeping SDN:"
    while read -r conf; do echo "    ${conf}"; done <<< "$ATTACHED"
  else
    SDN_CHANGED=0

    if pvesh get /cluster/sdn/vnets --output-format json | json_has vnet "$SDN_VNET"; then
      SUBNET_ID=$(pvesh get "/cluster/sdn/vnets/${SDN_VNET}/subnets" --output-format json | subnet_id "$SDN_SUBNET")
      if [[ -n "$SUBNET_ID" ]]; then
        log "Removing SDN subnet '${SUBNET_ID}'"
        run pvesh delete "/cluster/sdn/vnets/${SDN_VNET}/subnets/${SUBNET_ID}"
      fi
      log "Removing SDN vnet '${SDN_VNET}'"
      run pvesh delete "/cluster/sdn/vnets/${SDN_VNET}"
      SDN_CHANGED=1
    else
      log "SDN vnet '${SDN_VNET}' not found -> skipping"
    fi

    # Zone: only if no other vnets remain in it (OpenTofu-managed vnets must be destroyed first)
    if pvesh get /cluster/sdn/zones --output-format json | json_has zone "$SDN_ZONE"; then
      REMAINING=$(pvesh get /cluster/sdn/vnets --output-format json | python3 -c '
import json, sys
zone, skip = sys.argv[1], sys.argv[2]
print(sum(1 for v in json.load(sys.stdin) if v.get("zone") == zone and v.get("vnet") != skip))' \
        "$SDN_ZONE" "$SDN_VNET")
      if [[ "$REMAINING" != "0" ]]; then
        warn "Zone '${SDN_ZONE}' still has ${REMAINING} other vnet(s) -> keeping it (destroy the OpenTofu-managed vnets first)"
      else
        log "Removing SDN zone '${SDN_ZONE}'"
        run pvesh delete "/cluster/sdn/zones/${SDN_ZONE}"
        SDN_CHANGED=1
      fi
    fi

    if [[ $SDN_CHANGED -eq 1 ]]; then
      log "Applying SDN configuration"
      run pvesh set /cluster/sdn
    fi
  fi
fi

echo
log "Reset complete. Run dsoadm init (and dsoadm template) to bootstrap again."
