#!/usr/bin/env bash
# =============================================================
# pve-host.sh — Proxmox host onboarding (called by `dsoadm init`)
#   1) Create API user / roles / token for OpenTofu (Terraform)
#   2) Create the SDN network for the management node (skipped if present)
#   3) Create the management pool and empty operational pools,
#      and limit the API account to the operational pools (least privilege)
#   4) Download a Debian LXC template
#   5) Create and start the management LXC
#   6) Deliver API credentials and SSH keys into the LXC
#   7) Run mgmt-node.sh inside the LXC
#
# Run on : Proxmox host shell (as root)
# Usage  : dsoadm init                            (normal way)
#          CONFIG_FILE=/path/to/other.env ./pve-host.sh
#          ROTATE_TOKEN=1 ./pve-host.sh           (reissue the API token)
#          ACL_SCOPE=root ./pve-host.sh           (grant the whole datacenter; debugging only)
# Notes  : Uses only tools already on the host. Nothing is installed on the host.
# Re-run : Safe; existing resources are skipped.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ---------- Helpers ----------
log()  { echo -e "  \e[1;32m✔\e[0m $*"; }
warn() { echo -e "  \e[1;33m⚠\e[0m $*"; }
die()  { echo -e "  \e[1;31m✖\e[0m $*" >&2; exit 1; }
# Show a command's own output, indented and dimmed
indent() { sed -u $'s/^/      \e[2m/; s/$/\e[0m/'; }

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

# expect <what> <actual> <wanted>  -> warn when an existing resource differs from the config
SDN_MISMATCH=0
expect() {
  if [[ "$2" != "$3" ]]; then
    warn "${1}: found '${2}', config wants '${3}'. Not changing it."
    SDN_MISMATCH=1
  fi
}

# First config file found wins (dsoadm normally sets CONFIG_FILE already)
if [[ -z "${CONFIG_FILE:-}" ]]; then
  for f in /etc/proxmox-iac-bootstrap/bootstrap.env "${SCRIPT_DIR}/bootstrap.env"; do
    if [[ -f "$f" ]]; then CONFIG_FILE="$f"; break; fi
  done
fi
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-iac-bootstrap/bootstrap.env}"
load_config "$CONFIG_FILE"

# ---------- Defaults (used when not set in the config file) ----------
PROJECT_ID="${PROJECT_ID:-lab}"

SDN_ZONE="${SDN_ZONE:-lab}"
SDN_VNET="${SDN_VNET:-lmgmt}"
SDN_SUBNET="${SDN_SUBNET:-10.73.10.0/24}"
SDN_GATEWAY="${SDN_GATEWAY:-10.73.10.1}"

CTID="${CTID:-200}"
CT_HOSTNAME="${CT_HOSTNAME:-iac-mgmt}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-1024}"
CT_SWAP="${CT_SWAP:-512}"
CT_DISK="${CT_DISK:-10}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
TMPL_STORAGE="${TMPL_STORAGE:-local}"
CT_IP="${CT_IP:-10.73.10.10/24}"
CT_GW="${CT_GW:-$SDN_GATEWAY}"
BRIDGE="${BRIDGE:-$SDN_VNET}"
DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE-/root/.ssh/authorized_keys}"

TF_USER="${TF_USER:-terraform@pve}"
TF_ROLE="${TF_ROLE:-TerraformRole}"
TF_SDN_ROLE="${TF_SDN_ROLE:-TerraformSDNApply}"   # Only SDN.Allocate, granted on /sdn without propagation
TF_TOKEN_ID="${TF_TOKEN_ID:-provider}"
ROTATE_TOKEN="${ROTATE_TOKEN:-0}"
PVE_TLS_INSECURE="${PVE_TLS_INSECURE:-1}"   # 1 = skip the API certificate check (PVE's default cert is self-signed)

POOL_PREFIX="${POOL_PREFIX-lab}"            # "-" so an empty prefix is respected
OP_POOLS="${OP_POOLS:-tools k8s targets}"   # Operational pools OpenTofu may fill
ACL_SCOPE="${ACL_SCOPE:-narrow}"            # narrow = operational pools only; root = whole datacenter
NODE_NAME="${NODE_NAME:-$(hostname)}"
ALLOW_EXISTING_POOL="${ALLOW_EXISTING_POOL:-0}"
SET_TAG_COLORS="${SET_TAG_COLORS:-0}"

RUN_MGMT_SETUP="${RUN_MGMT_SETUP:-1}"
REPO_URL="${REPO_URL:-}"
REPO_LINK="${REPO_LINK:-}"
MGMT_SCRIPT="${MGMT_SCRIPT:-${SCRIPT_DIR}/mgmt-node.sh}"

# Derived values
PROJECT_MARKER="managed-by:${PROJECT_ID}"            # Stored only in pool comments
CRED_PATH="/root/.config/${PROJECT_ID}/credentials.env"
PVE_API_IP="${PVE_API_IP:-$SDN_GATEWAY}"              # Host address on the internal network
PVE_LAN_IP="${PVE_LAN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')}"
LAB_POOL="$(pool_name mgmt)"

WANTED_PRIVS=(
  Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit
  Pool.Allocate Pool.Audit
  Sys.Audit Sys.Console Sys.Modify
  SDN.Allocate SDN.Audit SDN.Use Mapping.Use User.Modify
  VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU
  VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options
  VM.Migrate VM.Monitor VM.PowerMgmt
)

TMP_CRED=""
cleanup() { if [[ -n "$TMP_CRED" ]]; then rm -f "$TMP_CRED"; fi; }
trap cleanup EXIT

# =============================================================
# 0. Pre-flight checks
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."
(( ${#SDN_VNET} <= 8 )) || die "SDN_VNET must be 8 characters or fewer."
[[ "$ACL_SCOPE" == "narrow" || "$ACL_SCOPE" == "root" ]] || die "ACL_SCOPE must be 'narrow' or 'root'."
[[ "$PVE_TLS_INSECURE" == "0" || "$PVE_TLS_INSECURE" == "1" ]] || die "PVE_TLS_INSECURE must be 0 or 1."
if [[ "$RUN_MGMT_SETUP" == "1" && ! -f "$MGMT_SCRIPT" ]]; then
  die "mgmt-node.sh not found at ${MGMT_SCRIPT} (or set RUN_MGMT_SETUP=0)."
fi
if [[ -n "$SSH_PUBKEY_FILE" && ! -s "$SSH_PUBKEY_FILE" ]]; then
  warn "SSH key file '${SSH_PUBKEY_FILE}' is missing or empty; SSH login to the LXC will not work."
  SSH_PUBKEY_FILE=""
fi

log "Proxmox : $(pveversion)"
if [[ -f "$CONFIG_FILE" ]]; then log "Config  : ${CONFIG_FILE}"; else log "Config  : (none, using defaults)"; fi
log "Plan    : LXC ${CTID} (${CT_HOSTNAME}) @ ${CT_IP} on ${BRIDGE}, pool ${LAB_POOL}"
log "ACL     : ${ACL_SCOPE}"

# =============================================================
# 1. Roles, user, token
# =============================================================
# Privilege names differ between PVE versions, so keep only those that exist
mapfile -t PRIVS < <(
  pveum role list --output-format json | python3 -c '
import json, sys
wanted = sys.argv[1:]
for r in json.load(sys.stdin):
    if r["roleid"] == "Administrator":
        p = r["privs"]
        avail = set(p.split(",") if isinstance(p, str) else p)
        for w in wanted:
            print(w if w in avail else "MISSING:" + w)' "${WANTED_PRIVS[@]}"
)
VALID_PRIVS=()
for p in "${PRIVS[@]}"; do
  if [[ "$p" == MISSING:* ]]; then
    warn "Privilege not available on this PVE version, skipping: ${p#MISSING:}"
  else
    VALID_PRIVS+=("$p")
  fi
done

# ensure_role <role> <privileges...>
ensure_role() {
  local role="$1"; shift
  if pveum role list --output-format json | json_has roleid "$role"; then
    log "Role '${role}' exists -> updating privileges"
    pveum role modify "$role" --privs "$*"
  else
    log "Creating role '${role}'"
    pveum role add "$role" --privs "$*"
  fi
}
ensure_role "$TF_ROLE" "${VALID_PRIVS[@]}"
# Applying pending SDN changes requires SDN.Allocate on /sdn itself
ensure_role "$TF_SDN_ROLE" SDN.Allocate

if pveum user list --output-format json | json_has userid "$TF_USER"; then
  log "User '${TF_USER}' already exists -> skipping"
else
  log "Creating user '${TF_USER}'"
  pveum user add "$TF_USER" --comment "IaC (OpenTofu/Terraform)"
fi
# Permissions (ACLs) are granted in step 3, after the pools exist.

TOKEN_VALUE=""
# The token value is shown only when issued, and it lives only in the management
# node's credentials file. Keep the token only while that file can still hold it.
if pveum user token list "$TF_USER" --output-format json | json_has tokenid "$TF_TOKEN_ID"; then
  if [[ "$ROTATE_TOKEN" == "1" ]]; then
    warn "Removing existing token and reissuing (ROTATE_TOKEN=1)"
    pveum user token remove "$TF_USER" "$TF_TOKEN_ID"
  elif ! pct status "$CTID" &>/dev/null; then
    warn "Management node ${CTID} will be created fresh and cannot know the old token -> reissuing"
    pveum user token remove "$TF_USER" "$TF_TOKEN_ID"
  elif ! pct exec "$CTID" -- test -f "$CRED_PATH" 2>/dev/null; then
    die "Token exists but ${CRED_PATH} is missing in LXC ${CTID}. Run: dsoadm init --rotate-token"
  else
    log "Token '${TF_USER}!${TF_TOKEN_ID}' already exists -> not reissuing"
  fi
fi
if ! pveum user token list "$TF_USER" --output-format json | json_has tokenid "$TF_TOKEN_ID"; then
  log "Issuing API token (privsep=0: inherits the user's privileges)"
  TOKEN_VALUE=$(
    pveum user token add "$TF_USER" "$TF_TOKEN_ID" --privsep 0 --output-format json \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"])'
  )
fi

# =============================================================
# 2. SDN network for the management node
# =============================================================
# Existing pieces are checked against the config but never modified.
SDN_CHANGED=0   # Apply only when something was created

ZONES_JSON=$(pvesh get /cluster/sdn/zones --output-format json)
if json_has zone "$SDN_ZONE" <<<"$ZONES_JSON"; then
  log "SDN zone '${SDN_ZONE}' already exists -> checking"
  expect "Zone ${SDN_ZONE} type" "$(json_get zone "$SDN_ZONE" type <<<"$ZONES_JSON")" simple
else
  log "Creating SDN zone '${SDN_ZONE}' (simple)"
  pvesh create /cluster/sdn/zones --zone "$SDN_ZONE" --type simple
  SDN_CHANGED=1
fi

VNETS_JSON=$(pvesh get /cluster/sdn/vnets --output-format json)
if json_has vnet "$SDN_VNET" <<<"$VNETS_JSON"; then
  log "SDN vnet '${SDN_VNET}' already exists -> checking"
  expect "VNet ${SDN_VNET} zone" "$(json_get vnet "$SDN_VNET" zone <<<"$VNETS_JSON")" "$SDN_ZONE"
else
  log "Creating SDN vnet '${SDN_VNET}'"
  pvesh create /cluster/sdn/vnets --vnet "$SDN_VNET" --zone "$SDN_ZONE"
  SDN_CHANGED=1
fi

SUBNETS_JSON=$(pvesh get "/cluster/sdn/vnets/${SDN_VNET}/subnets" --output-format json)
EXISTING_SUBNET=$(subnet_id "$SDN_SUBNET" <<<"$SUBNETS_JSON")
if [[ -n "$EXISTING_SUBNET" ]]; then
  log "SDN subnet '${SDN_SUBNET}' already exists -> checking"
  expect "Subnet ${SDN_SUBNET} gateway" "$(json_get subnet "$EXISTING_SUBNET" gateway <<<"$SUBNETS_JSON")" "$SDN_GATEWAY"
  expect "Subnet ${SDN_SUBNET} snat" "$(json_get subnet "$EXISTING_SUBNET" snat <<<"$SUBNETS_JSON")" 1
else
  log "Creating SDN subnet '${SDN_SUBNET}' (gateway ${SDN_GATEWAY}, SNAT on)"
  pvesh create "/cluster/sdn/vnets/${SDN_VNET}/subnets" \
    --subnet "$SDN_SUBNET" --type subnet --gateway "$SDN_GATEWAY" --snat 1
  SDN_CHANGED=1
fi
if [[ $SDN_MISMATCH -eq 1 ]]; then
  warn "The existing SDN setup differs from the config (see above). Fix one or the other if the LXC has no network."
fi

if [[ $SDN_CHANGED -eq 1 ]]; then
  log "Applying SDN configuration"
  pvesh set /cluster/sdn 2>&1 | indent
fi

for _ in $(seq 1 15); do
  if ip link show "$BRIDGE" &>/dev/null; then break; fi
  sleep 2
done
ip link show "$BRIDGE" &>/dev/null || die "Bridge '${BRIDGE}' not found."

# =============================================================
# 3. Pools and permissions
# =============================================================
# Pool comments carry PROJECT_MARKER so a pool the user created
# for something else is never adopted silently.
ensure_pool() {  # ensure_pool <name> <description>
  local pool="$1" desc="$2" comment
  if pvesh get /pools --output-format json | json_has poolid "$pool"; then
    comment=$(pvesh get /pools --output-format json | json_get poolid "$pool" comment)
    if [[ "$comment" == *"$PROJECT_MARKER"* ]]; then
      log "Pool '${pool}' already exists -> skipping"
    elif [[ "$ALLOW_EXISTING_POOL" == "1" ]]; then
      warn "Reusing pool '${pool}' not created by this project (ALLOW_EXISTING_POOL=1)"
    else
      die "Pool '${pool}' exists but was not created by this project. Change POOL_PREFIX or set ALLOW_EXISTING_POOL=1."
    fi
  else
    log "Creating pool '${pool}'"
    pvesh create /pools --poolid "$pool" --comment "${desc} [${PROJECT_MARKER}]"
  fi
}

ensure_pool "$LAB_POOL" "Management node"
OP_POOL_NAMES=()
for p in $OP_POOLS; do
  OP_POOL_NAMES+=("$(pool_name "$p")")
  ensure_pool "$(pool_name "$p")" "Operational pool (OpenTofu)"
done

# acl_has <path> <role>  -> exit 0 if TF_USER already has that role on that path
acl_has() {
  pveum acl list --output-format json | python3 -c '
import json, sys
path, user, role = sys.argv[1:4]
sys.exit(0 if any(a.get("path") == path and a.get("ugid") == user and a.get("roleid") == role
                  for a in json.load(sys.stdin)) else 1)' "$1" "$TF_USER" "$2"
}

# grant <path> <role> [propagate: 1|0]
#   propagate=0 applies the role to that exact path only, not to anything below it
grant() {
  local propagate="${3:-1}"
  if acl_has "$1" "$2"; then
    log "ACL ${1} -> ${2} already set"
  else
    log "Granting ${2} on ${1} (propagate=${propagate})"
    pveum acl modify "$1" --users "$TF_USER" --roles "$2" --propagate "$propagate"
  fi
}

if [[ "$ACL_SCOPE" == "root" ]]; then
  warn "ACL_SCOPE=root: '${TF_USER}' can manage the whole datacenter"
  grant / "$TF_ROLE"
else
  # Remove the datacenter-wide grant left by earlier versions of this script
  if acl_has / "$TF_ROLE"; then
    log "Removing datacenter-wide ACL (/) from '${TF_USER}'"
    pveum acl delete / --users "$TF_USER" --roles "$TF_ROLE"
  fi
  for pool in "${OP_POOL_NAMES[@]}"; do
    grant "/pool/${pool}" "$TF_ROLE"             # Guests inside the operational pools
  done
  grant "/storage/${CT_STORAGE}" "$TF_ROLE"      # Disks for new guests
  grant "/storage/${TMPL_STORAGE}" "$TF_ROLE"    # Templates
  grant "/sdn/zones/${SDN_ZONE}" "$TF_ROLE"      # VNets inside the zone
  grant /sdn "$TF_SDN_ROLE" 0                    # Apply pending SDN changes only; not inherited by zones
  grant "/nodes/${NODE_NAME}" PVEAuditor         # Read-only node information
fi

# =============================================================
# 4. Debian template
# =============================================================
# Use a template already in storage if there is one; only go online when needed
TEMPLATE=$(
  pveam list "$TMPL_STORAGE" | awk '{print $1}' | sed 's#.*/##' \
    | grep -E "^debian-${DEBIAN_VERSION}-standard_" | sort -V | tail -n1 || true
)
if [[ -n "$TEMPLATE" ]]; then
  log "Template '${TEMPLATE}' already present -> skipping download"
else
  log "Refreshing template list (can take a minute)"
  timeout 120 pveam update >/dev/null || warn "pveam update failed or timed out; using the cached list"
  TEMPLATE=$(
    pveam available --section system | awk '{print $2}' \
      | grep -E "^debian-${DEBIAN_VERSION}-standard_" | sort -V | tail -n1 || true
  )
  [[ -n "$TEMPLATE" ]] || die "No debian-${DEBIAN_VERSION} template found."
  log "Downloading template: ${TEMPLATE}"
  pveam download "$TMPL_STORAGE" "$TEMPLATE" 2>&1 | indent
fi

# =============================================================
# 5. Management LXC
# =============================================================
# Markdown shown in the Proxmox UI "Summary -> Notes" panel
CT_DESCRIPTION=$(cat <<EOF
## ${CT_HOSTNAME}
Management node for **OpenTofu** and **Ansible**.

- Pool: \`${LAB_POOL}\`
- Network: \`${BRIDGE}\` (${CT_IP})
- Do not manage this container with OpenTofu/Terraform.
EOF
)

if pct status "$CTID" &>/dev/null; then
  EXISTING_HN=$(pct config "$CTID" | awk '/^hostname:/ {print $2}')
  [[ "$EXISTING_HN" == "$CT_HOSTNAME" ]] \
    || die "CTID ${CTID} is used by another container ('${EXISTING_HN}'). Choose a different CTID."
  log "LXC ${CTID} (${CT_HOSTNAME}) already exists -> skipping creation"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
  if [[ "$CT_IP" != "dhcp" ]]; then NET0+=",gw=${CT_GW}"; fi
  CREATE_ARGS=(
    --hostname "$CT_HOSTNAME"
    --cores "$CT_CORES" --memory "$CT_MEMORY" --swap "$CT_SWAP"
    --rootfs "${CT_STORAGE}:${CT_DISK}"
    --net0 "$NET0"
    --ostype debian
    --unprivileged 1          # Isolated from host root
    --features nesting=1      # Needed by modern systemd
    --onboot 1                # Start with the host
    --pool "$LAB_POOL"
    --tags "mgmt;bootstrap"   # What it is; who created it
    --description "$CT_DESCRIPTION"
  )
  log "Creating LXC ${CTID} (${CT_HOSTNAME}) on ${BRIDGE} (${CT_IP})"
  pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" "${CREATE_ARGS[@]}" 2>&1 | indent
fi

if ! pct status "$CTID" | grep -q running; then
  log "Starting LXC ${CTID}"
  pct start "$CTID"
fi

# Gateway -> internet (SNAT) -> DNS, reporting where it breaks
log "Checking network from inside the LXC..."
NET_OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null; then NET_OK=1; break; fi
  sleep 2
done
if [[ $NET_OK -ne 1 ]]; then
  pct exec "$CTID" -- ping -c1 -W2 "$CT_GW" &>/dev/null \
    || die "Cannot reach gateway ${CT_GW}. Check bridge/IP settings."
  pct exec "$CTID" -- ping -c1 -W2 1.1.1.1 &>/dev/null \
    || die "Gateway OK but no internet. Check SNAT on subnet ${SDN_SUBNET}."
  die "Internet OK but DNS fails. Check /etc/resolv.conf inside the LXC."
fi
log "Network OK (gateway, SNAT, DNS)"

# =============================================================
# 6. Credentials and SSH keys into the LXC
# =============================================================
# Env var names are the ones the bpg/proxmox provider reads automatically.
# The token is never printed; it lives only in a root-only file inside the LXC.
if [[ "$PVE_TLS_INSECURE" == "1" ]]; then INSECURE_VALUE=true; else INSECURE_VALUE=false; fi
if [[ -n "$TOKEN_VALUE" ]]; then
  TMP_CRED=$(mktemp)
  chmod 600 "$TMP_CRED"
  cat > "$TMP_CRED" <<EOF
# Proxmox API credentials — never commit this file
export PROXMOX_VE_ENDPOINT="https://${PVE_API_IP}:8006/"
export PROXMOX_VE_API_TOKEN="${TF_USER}!${TF_TOKEN_ID}=${TOKEN_VALUE}"
export PROXMOX_VE_INSECURE="${INSECURE_VALUE}"
EOF
  pct exec "$CTID" -- install -d -m 700 "$(dirname "$CRED_PATH")"
  pct push "$CTID" "$TMP_CRED" "$CRED_PATH" --perms 600
  log "Credentials saved: ${CRED_PATH} inside LXC ${CTID}"
fi

# Merge the host's authorized keys into the LXC (works for new and existing LXCs).
# Keys already in the LXC are kept.
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  log "Syncing SSH keys from ${SSH_PUBKEY_FILE}"
  pct exec "$CTID" -- install -d -m 700 /root/.ssh
  pct push "$CTID" "$SSH_PUBKEY_FILE" /root/.ssh/incoming_keys --perms 600
  pct exec "$CTID" -- bash -c '
    touch /root/.ssh/authorized_keys
    cat /root/.ssh/authorized_keys /root/.ssh/incoming_keys | grep -v "^[[:space:]]*$" | sort -u > /root/.ssh/merged_keys
    mv /root/.ssh/merged_keys /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    rm -f /root/.ssh/incoming_keys'
fi

# =============================================================
# 7. Run mgmt-node.sh inside the LXC
# =============================================================
if [[ "$RUN_MGMT_SETUP" == "1" ]]; then
  log "Running mgmt-node.sh inside LXC ${CTID}"
  pct push "$CTID" "$MGMT_SCRIPT" /root/mgmt-node.sh --perms 700
  pct exec "$CTID" -- env HOME=/root PROJECT_ID="$PROJECT_ID" CRED_FILE="$CRED_PATH" \
    REPO_URL="$REPO_URL" REPO_LINK="$REPO_LINK" \
    bash /root/mgmt-node.sh
else
  log "Skipping mgmt-node.sh (RUN_MGMT_SETUP=0)"
fi

# =============================================================
# 8. Optional: tag colors (cluster-wide, replaces any existing color map)
# =============================================================
if [[ "$SET_TAG_COLORS" == "1" ]]; then
  log "Applying tag colors"
  pvesh set /cluster/options --tag-style "color-map=mgmt:1565C0:FFFFFF;bootstrap:546E7A:FFFFFF"
fi

summary_box() {
cat <<EOF

────────────────────────────────────────────
 Done: LXC ${CTID} (${CT_HOSTNAME}) @ ${CT_IP%/*}

 On the host:  pct enter ${CTID}

 From your PC, add to ~/.ssh/config:

   Host pve
     HostName ${PVE_LAN_IP:-<proxmox-host-ip>}
     User root

   Host ${CT_HOSTNAME}
     HostName ${CT_IP%/*}
     User root
     ProxyJump pve

 Then: ssh ${CT_HOSTNAME}
────────────────────────────────────────────
EOF
}
# dsoadm prints this after the facts step, so it is the last thing on screen
if [[ -n "${DSO_SUMMARY_FILE:-}" ]]; then summary_box > "$DSO_SUMMARY_FILE"; else summary_box; fi
