# shellcheck shell=bash
# shellcheck disable=SC2034  # many variables here are set for the scripts that source this file
# =============================================================
# lib.sh — shared by dsoadm and the pve-*.sh scripts (sourced, not run)
#
# Environments: every resource belongs to one named environment (ENV_NAME,
# default "lab"). Its settings live in envs/<name>.env, and envs/<name>.state
# lists what `dsoadm init` / `dsoadm template` actually created. Reset removes
# only what that state file lists, so environments never delete each other.
# =============================================================

ETC_DIR="${ETC_DIR:-/etc/proxmox-iac-bootstrap}"
ENVS_DIR="${ETC_DIR}/envs"
ENV_RE='^[a-z][a-z0-9]{0,5}$'     # 6 characters max: the VNet ID "<env>mg" must stay within 8
VNET_RE='^[a-z][a-z0-9]{0,7}$'    # Proxmox SDN: 8 characters, letters and digits

log()  { echo -e "  \e[1;32m✔\e[0m $*"; }
warn() { echo -e "  \e[1;33m⚠\e[0m $*"; }
die()  { echo -e "  \e[1;31m✖\e[0m $*" >&2; exit 1; }
# Show a command's own output, indented and dimmed
indent() { sed -u $'s/^/      \e[2m/; s/$/\e[0m/'; }

# ---------- Config files (KEY=VALUE, read, never executed) ----------
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

# set_config <file> <KEY> <value>  -> replace the KEY line, or append it
set_config() {
  local file="$1" key="$2" value="$3" tmp line found=0
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "${line%%=*}" == "$key" ]]; then echo "${key}=${value}"; found=1; else echo "$line"; fi
    done < "$file" > "$tmp"
  fi
  if [[ $found -eq 0 ]]; then echo "${key}=${value}" >> "$tmp"; fi
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

# ---------- JSON helpers (python3 ships with Proxmox) ----------
# <json array> | json_has <key> <value>   -> exit 0 if any item matches
json_has() {
  python3 -c '
import json, sys
key, val = sys.argv[1], sys.argv[2]
sys.exit(0 if any(str(d.get(key)) == val for d in json.load(sys.stdin)) else 1)' "$1" "$2"
}

# <json array> | json_get <key> <value> <field>   -> print field of first match
json_get() {
  python3 -c '
import json, sys
key, val, field = sys.argv[1:4]
for d in json.load(sys.stdin):
    if str(d.get(key)) == val:
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

# net_addr <cidr> <n>   -> host n of the subnet;  <n>/ adds the prefix length
#   net_addr 10.70.10.0/24 1 -> 10.70.10.1        net_addr 10.70.10.0/24 10/ -> 10.70.10.10/24
net_addr() {
  python3 -c '
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(0)
n, with_prefix = sys.argv[2].rstrip("/"), sys.argv[2].endswith("/")
addr = net.network_address + int(n)
print(f"{addr}/{net.prefixlen}" if with_prefix else addr)' "$1" "$2"
}

# ---------- Environments ----------
env_validate() {
  [[ "$1" =~ $ENV_RE ]] || die "Environment name '${1}': lowercase letters and digits, starting with a letter, 6 characters max."
}

env_list() {  # one name per line
  local f
  for f in "${ENVS_DIR}"/*.env; do
    if [[ -f "$f" ]]; then f="${f##*/}"; echo "${f%.env}"; fi
  done
}

# v0.1 kept a single /etc/proxmox-iac-bootstrap/bootstrap.env; it becomes env "lab"
migrate_legacy_config() {
  local old="${ETC_DIR}/bootstrap.env"
  if [[ -f "$old" && ! -e "${ENVS_DIR}/lab.env" ]]; then
    install -d -m 700 "$ENVS_DIR"
    mv "$old" "${ENVS_DIR}/lab.env"
    warn "Moved ${old} to ${ENVS_DIR}/lab.env (environment 'lab')"
  fi
}

# select_env  -> sets ENV_NAME, CONFIG_FILE, STATE_FILE and loads the config
select_env() {
  ENV_NAME="${DSO_ENV:-lab}"
  env_validate "$ENV_NAME"
  CONFIG_FILE="${CONFIG_FILE:-${ENVS_DIR}/${ENV_NAME}.env}"
  STATE_FILE="${ENVS_DIR}/${ENV_NAME}.state"
  load_config "$CONFIG_FILE"
}

# apply_defaults  -> every setting not given gets its default, derived from ENV_NAME
apply_defaults() {
  PROJECT_ID="$ENV_NAME"                       # Marker, credentials path, clone dir
  SDN_ZONE="${SDN_ZONE:-$ENV_NAME}"
  SDN_VNET="${SDN_VNET:-${ENV_NAME}mg}"
  SDN_VNET_ALIAS="${SDN_VNET_ALIAS:-${ENV_NAME}-mgmt}"
  SDN_SUBNET="${SDN_SUBNET:-10.73.10.0/24}"
  SDN_GATEWAY="${SDN_GATEWAY:-$(net_addr "$SDN_SUBNET" 1)}"

  CTID="${CTID:-200}"
  CT_HOSTNAME="${CT_HOSTNAME:-${ENV_NAME}-mgmt}"
  CT_CORES="${CT_CORES:-1}"
  CT_MEMORY="${CT_MEMORY:-1024}"
  CT_SWAP="${CT_SWAP:-512}"
  CT_DISK="${CT_DISK:-10}"
  CT_STORAGE="${CT_STORAGE:-local-lvm}"
  TMPL_STORAGE="${TMPL_STORAGE:-local}"
  CT_IP="${CT_IP:-$(net_addr "$SDN_SUBNET" 10/)}"
  CT_GW="${CT_GW:-$SDN_GATEWAY}"
  BRIDGE="${BRIDGE:-$SDN_VNET}"
  DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
  SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE-/root/.ssh/authorized_keys}"

  TF_USER="${TF_USER:-iac-${ENV_NAME}@pve}"
  TF_ROLE="${TF_ROLE:-IaC-${ENV_NAME}}"
  TF_SDN_ROLE="${TF_SDN_ROLE:-IaC-${ENV_NAME}-SDN}"      # Only SDN.Allocate, on /sdn without propagation
  TF_CLONE_ROLE="${TF_CLONE_ROLE:-IaC-${ENV_NAME}-Clone}"
  TF_TOKEN_ID="${TF_TOKEN_ID:-provider}"
  PVE_TLS_INSECURE="${PVE_TLS_INSECURE:-1}"

  POOL_PREFIX="${POOL_PREFIX-$ENV_NAME}"        # "-" so an empty prefix is respected
  OP_POOLS="${OP_POOLS:-workloads}"
  ACL_SCOPE="${ACL_SCOPE:-narrow}"
  ALLOW_EXISTING_POOL="${ALLOW_EXISTING_POOL:-0}"

  TEMPLATE_NAME="${TEMPLATE_NAME:-debian-12-cloud}"
  TEMPLATE_VMID="${TEMPLATE_VMID:-}"            # Picked by `dsoadm template`, then saved

  PROJECT_MARKER="managed-by:${PROJECT_ID}"
  CRED_PATH="/root/.config/${PROJECT_ID}/credentials.env"
}

# pool_name mgmt -> <prefix>-mgmt (or "mgmt" when the prefix is empty)
pool_name() {
  if [[ -n "$POOL_PREFIX" ]]; then echo "${POOL_PREFIX}-$1"; else echo "$1"; fi
}

# ---------- State: what this environment created ----------
# One "<type> <id>" per line. Types: role user zone vnet subnet pool lxc vm
state_add() {
  install -d -m 700 "$ENVS_DIR"
  if ! state_has "$1" "$2"; then echo "$1 $2" >> "$STATE_FILE"; chmod 600 "$STATE_FILE"; fi
}
state_has()  { [[ -f "$STATE_FILE" ]] && grep -qxF "$1 $2" "$STATE_FILE"; }
state_list() { if [[ -f "$STATE_FILE" ]]; then awk -v t="$1" '$1 == t {print $2}' "$STATE_FILE"; fi; }
state_remove() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -vxF "$1 $2" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  if [[ ! -s "$STATE_FILE" ]]; then rm -f "$STATE_FILE"; fi
}

# state_owner <type> <id>  -> name of the OTHER environment that created it, if any
state_owner() {
  local f name
  for f in "${ENVS_DIR}"/*.state; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"; name="${name%.state}"
    if [[ "$name" != "$ENV_NAME" ]] && grep -qxF "$1 $2" "$f"; then echo "$name"; return 0; fi
  done
  return 1
}

# not_others <type> <id> <what>  -> stop if another environment owns it
not_others() {
  local owner
  if owner=$(state_owner "$1" "$2"); then
    die "${3} belongs to environment '${owner}'. Pick another value for '${ENV_NAME}'."
  fi
}

# sdn_subnets  -> every subnet CIDR defined in SDN, one per line
sdn_subnets() {
  local v
  for v in $(pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null \
               | python3 -c 'import json,sys; [print(d["vnet"]) for d in json.load(sys.stdin)]' 2>/dev/null); do
    pvesh get "/cluster/sdn/vnets/${v}/subnets" --output-format json 2>/dev/null \
      | python3 -c 'import json,sys; [print(d.get("cidr","")) for d in json.load(sys.stdin)]' 2>/dev/null || true
  done
}

# ---------- Free values for a new environment ----------
# Taken = exists on the host OR is set in any environment's config
_taken_in_configs() {  # <KEY>  -> values of KEY across all env configs
  local f
  for f in "${ENVS_DIR}"/*.env; do
    if [[ -f "$f" ]]; then grep -E "^$1=" "$f" | tail -n1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//'; fi
  done
}

free_id() {  # free_id <start>  -> first VMID/CTID from <start> that nothing uses
  local id="$1" taken
  taken=" $(_taken_in_configs CTID | tr '\n' ' ') $(_taken_in_configs TEMPLATE_VMID | tr '\n' ' ') "
  while qm status "$id" &>/dev/null || pct status "$id" &>/dev/null || [[ "$taken" == *" $id "* ]]; do
    id=$((id + 1))
  done
  echo "$id"
}

free_subnet() {  # first 10.N.10.0/24 (N from 73) not used by an SDN subnet or another config
  local used
  used="$( { sdn_subnets; _taken_in_configs SDN_SUBNET; } | tr '\n' ' ')"
  python3 -c '
import ipaddress, sys
used = [ipaddress.ip_network(u, strict=False) for u in sys.argv[1].split() if u]
for n in range(73, 255):
    cand = ipaddress.ip_network(f"10.{n}.10.0/24")
    if not any(cand.overlaps(u) for u in used):
        print(cand); break' "$used"
}
