#!/usr/bin/env bash
# =============================================================
# pve-host.sh — Proxmox host onboarding for one environment (`dsoadm init`)
#   1) API user / roles / token for OpenTofu
#   2) SDN network for the management node (existing pieces are checked, not changed)
#   3) Management pool + operational pools, API account limited to the latter
#   4) Debian LXC template
#   5) Management LXC
#   6) API credentials and SSH keys into the LXC
#   7) mgmt-node.sh inside the LXC
# Everything it creates is recorded in envs/<env>.state; reset removes only that.
#
# Run on : Proxmox host shell (as root), via `dsoadm init [--env NAME]`
# Re-run : Safe; existing resources are skipped.
# =============================================================
set -euo pipefail
# A restrictive umask (e.g. 077) makes `pct create` fail for unprivileged
# containers: the container's root cannot enter its own rootfs folder.
umask 022

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bootstrap/lib.sh
. "${SCRIPT_DIR}/lib.sh"

select_env
apply_defaults

ROTATE_TOKEN="${ROTATE_TOKEN:-0}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
SET_TAG_COLORS="${SET_TAG_COLORS:-0}"
RUN_MGMT_SETUP="${RUN_MGMT_SETUP:-1}"
REPO_URL="${REPO_URL:-}"
REPO_LINK="${REPO_LINK:-}"
MGMT_SCRIPT="${MGMT_SCRIPT:-${SCRIPT_DIR}/mgmt-node.sh}"
PVE_API_IP="${PVE_API_IP:-$SDN_GATEWAY}"              # Host address on the internal network
PVE_LAN_IP="${PVE_LAN_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')}"
MGMT_POOL="$(pool_name mgmt)"

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

# expect <what> <actual> <wanted>  -> warn when an existing resource differs from the config
SDN_MISMATCH=0
expect() {
  if [[ "$2" != "$3" ]]; then
    warn "${1}: found '${2}', config wants '${3}'. Not changing it."
    SDN_MISMATCH=1
  fi
}

# =============================================================
# 0. Pre-flight checks
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."
[[ "$SDN_VNET" =~ $VNET_RE ]] || die "SDN_VNET '${SDN_VNET}': lowercase letters and digits, starting with a letter, 8 characters max."
[[ -n "$SDN_GATEWAY" ]] || die "SDN_SUBNET '${SDN_SUBNET}' is not a valid subnet."
[[ "$ACL_SCOPE" == "narrow" || "$ACL_SCOPE" == "root" ]] || die "ACL_SCOPE must be 'narrow' or 'root'."
[[ "$PVE_TLS_INSECURE" == "0" || "$PVE_TLS_INSECURE" == "1" ]] || die "PVE_TLS_INSECURE must be 0 or 1."
if [[ "$RUN_MGMT_SETUP" == "1" && ! -f "$MGMT_SCRIPT" ]]; then
  die "mgmt-node.sh not found at ${MGMT_SCRIPT} (or set RUN_MGMT_SETUP=0)."
fi
if [[ -n "$SSH_PUBKEY_FILE" && ! -s "$SSH_PUBKEY_FILE" ]]; then
  warn "SSH key file '${SSH_PUBKEY_FILE}' is missing or empty; SSH login to the LXC will not work."
  SSH_PUBKEY_FILE=""
fi

# Nothing another environment created may be reused
not_others zone   "$SDN_ZONE"    "SDN zone '${SDN_ZONE}'"
not_others vnet   "$SDN_VNET"    "SDN vnet '${SDN_VNET}'"
not_others lxc    "$CTID"        "CTID ${CTID}"
not_others user   "$TF_USER"     "API user '${TF_USER}'"
not_others pool   "$MGMT_POOL"   "Pool '${MGMT_POOL}'"
for p in $OP_POOLS; do not_others pool "$(pool_name "$p")" "Pool '$(pool_name "$p")'"; done

log "Environment : ${ENV_NAME}"
log "Proxmox     : $(pveversion)"
if [[ -f "$CONFIG_FILE" ]]; then log "Config      : ${CONFIG_FILE}"; else log "Config      : (none, using defaults)"; fi
log "Plan        : LXC ${CTID} (${CT_HOSTNAME}) @ ${CT_IP} on ${SDN_VNET_ALIAS} (vnet ${SDN_VNET}), pool ${MGMT_POOL}"
log "ACL         : ${ACL_SCOPE}"

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
    state_add role "$role"
  fi
}
ensure_role "$TF_ROLE" "${VALID_PRIVS[@]}"
# Applying pending SDN changes requires SDN.Allocate on /sdn itself
ensure_role "$TF_SDN_ROLE" SDN.Allocate

if pveum user list --output-format json | json_has userid "$TF_USER"; then
  log "User '${TF_USER}' already exists -> skipping"
else
  log "Creating user '${TF_USER}'"
  pveum user add "$TF_USER" --comment "IaC (OpenTofu) for environment ${ENV_NAME} [${PROJECT_MARKER}]"
  state_add user "$TF_USER"
fi

TOKEN_VALUE=""
# The token value is shown only when issued, and it lives only in the management
# node's credentials file. Keep the token only while that file can still hold it.
if pveum user token list "$TF_USER" --output-format json | json_has tokenid "$TF_TOKEN_ID"; then
  if [[ "$ROTATE_TOKEN" == "1" ]]; then
    warn "Removing existing token and reissuing (--rotate-token)"
    pveum user token remove "$TF_USER" "$TF_TOKEN_ID"
  elif ! pct status "$CTID" &>/dev/null; then
    warn "Management node ${CTID} will be created fresh and cannot know the old token -> reissuing"
    pveum user token remove "$TF_USER" "$TF_TOKEN_ID"
  elif ! pct exec "$CTID" -- test -f "$CRED_PATH" 2>/dev/null; then
    die "Token exists but ${CRED_PATH} is missing in LXC ${CTID}. Run: dsoadm init --env ${ENV_NAME} --rotate-token"
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
SDN_CHANGED=0   # Apply only when something was created

ZONES_JSON=$(pvesh get /cluster/sdn/zones --output-format json)
if json_has zone "$SDN_ZONE" <<<"$ZONES_JSON"; then
  log "SDN zone '${SDN_ZONE}' already exists -> checking"
  expect "Zone ${SDN_ZONE} type" "$(json_get zone "$SDN_ZONE" type <<<"$ZONES_JSON")" simple
else
  log "Creating SDN zone '${SDN_ZONE}' (simple)"
  pvesh create /cluster/sdn/zones --zone "$SDN_ZONE" --type simple
  state_add zone "$SDN_ZONE"
  SDN_CHANGED=1
fi

VNETS_JSON=$(pvesh get /cluster/sdn/vnets --output-format json)
if json_has vnet "$SDN_VNET" <<<"$VNETS_JSON"; then
  log "SDN vnet '${SDN_VNET}' already exists -> checking"
  expect "VNet ${SDN_VNET} zone" "$(json_get vnet "$SDN_VNET" zone <<<"$VNETS_JSON")" "$SDN_ZONE"
else
  log "Creating SDN vnet '${SDN_VNET}' (${SDN_VNET_ALIAS})"
  pvesh create /cluster/sdn/vnets --vnet "$SDN_VNET" --zone "$SDN_ZONE" --alias "$SDN_VNET_ALIAS"
  state_add vnet "$SDN_VNET"
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
  EXISTING_SUBNET=$(pvesh get "/cluster/sdn/vnets/${SDN_VNET}/subnets" --output-format json | subnet_id "$SDN_SUBNET")
  state_add subnet "${SDN_VNET}/${EXISTING_SUBNET}"
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
# Pool comments carry PROJECT_MARKER so a pool someone created
# for something else is never adopted silently.
ensure_pool() {  # ensure_pool <name> <description>
  local pool="$1" desc="$2" comment
  if pvesh get /pools --output-format json | json_has poolid "$pool"; then
    comment=$(pvesh get /pools --output-format json | json_get poolid "$pool" comment)
    if [[ "$comment" == *"$PROJECT_MARKER"* ]]; then
      log "Pool '${pool}' already exists -> skipping"
    elif [[ "$ALLOW_EXISTING_POOL" == "1" ]]; then
      warn "Reusing pool '${pool}' not created by this environment (ALLOW_EXISTING_POOL=1)"
    else
      die "Pool '${pool}' exists but was not created by environment '${ENV_NAME}'. Change POOL_PREFIX or set ALLOW_EXISTING_POOL=1."
    fi
  else
    log "Creating pool '${pool}'"
    pvesh create /pools --poolid "$pool" --comment "${desc} [${PROJECT_MARKER}]"
    state_add pool "$pool"
  fi
}

ensure_pool "$MGMT_POOL" "Management node"
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
# 4. Debian template (a shared download cache, not part of any environment)
# =============================================================
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
CT_DESCRIPTION=$(cat <<EOF
## ${CT_HOSTNAME}
Management node for **OpenTofu** and **Ansible**, environment \`${ENV_NAME}\`.

- Pool: \`${MGMT_POOL}\`
- Network: \`${SDN_VNET_ALIAS}\` (vnet \`${SDN_VNET}\`, ${CT_IP})
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
    --unprivileged 1
    --features nesting=1
    --onboot 1
    --pool "$MGMT_POOL"
    --tags "mgmt;bootstrap;env-${ENV_NAME}"
    --description "$CT_DESCRIPTION"
  )
  log "Creating LXC ${CTID} (${CT_HOSTNAME}) on ${SDN_VNET_ALIAS} (${CT_IP})"
  pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" "${CREATE_ARGS[@]}" 2>&1 | indent
  state_add lxc "$CTID"
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
# Proxmox API credentials for environment ${ENV_NAME} — never commit this file
export PROXMOX_VE_ENDPOINT="https://${PVE_API_IP}:8006/"
export PROXMOX_VE_API_TOKEN="${TF_USER}!${TF_TOKEN_ID}=${TOKEN_VALUE}"
export PROXMOX_VE_INSECURE="${INSECURE_VALUE}"
EOF
  pct exec "$CTID" -- install -d -m 700 "$(dirname "$CRED_PATH")"
  pct push "$CTID" "$TMP_CRED" "$CRED_PATH" --perms 600
  log "Credentials saved: ${CRED_PATH} inside LXC ${CTID}"
fi

# Merge the host's authorized keys into the LXC; keys already there are kept
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
 Done: environment ${ENV_NAME}
   LXC ${CTID} (${CT_HOSTNAME}) @ ${CT_IP%/*} on ${SDN_VNET_ALIAS}

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
