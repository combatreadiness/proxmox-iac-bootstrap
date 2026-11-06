#!/usr/bin/env bash
# =============================================================
# pve-reset.sh — Undo what `dsoadm init` / `dsoadm template` created for ONE environment
#   Removes only what envs/<env>.state lists, checking each item before removing it:
#   management LXC, VM template, pools (if empty), API user (tokens and ACLs go with it),
#   roles, and with RESET_SDN=1 the subnet / vnet / zone.
#   Other environments and anything this environment did not create are never touched.
#
# Run on : Proxmox host shell (as root), via `dsoadm reset [--env NAME]`
# Options (environment variables, set by dsoadm):
#   DRY_RUN=1    show what would be removed       FORCE=1   no confirmation
#   RESET_SDN=1  also remove the SDN network      PURGE=1   also remove guests in the
#                                                           environment's pools (TEARDOWN_CMD first)
# Keeps  : downloaded images and templates on storage (a cache shared by all environments)
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bootstrap/lib.sh
. "${SCRIPT_DIR}/lib.sh"

select_env
apply_defaults

DRY_RUN="${DRY_RUN:-0}"
RESET_SDN="${RESET_SDN:-0}"
FORCE="${FORCE:-0}"
PURGE="${PURGE:-0}"
TEARDOWN_CMD="${TEARDOWN_CMD:-}"   # Runs inside the management LXC before a purge

# Execute a command, or only print it in dry-run mode
run() {
  if [[ "$DRY_RUN" == "1" ]]; then echo -e "    \e[1;36m[dry-run]\e[0m $*"; else "$@"; fi
}
# Forget an item once it is gone (not in dry-run)
gone() { if [[ "$DRY_RUN" != "1" ]]; then state_remove "$1" "$2"; fi; }

# <pool>  -> one line per guest: "<type> <vmid> <name>"
pool_guests() {
  if pvesh get /pools --output-format json | json_has poolid "$1"; then
    pvesh get "/pools/$1" --output-format json | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("members", []):
    if m.get("type") in ("lxc", "qemu"):
        print(m["type"], m["vmid"], m.get("name", "-"))'
  fi
}

# =============================================================
# 0. What does this environment own?
# =============================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pveversion >/dev/null || die "This script must run on a Proxmox VE host."
if [[ ! -f "$STATE_FILE" ]]; then
  log "Environment '${ENV_NAME}' has nothing recorded (${STATE_FILE}) -> nothing to reset"
  exit 0
fi

mapfile -t S_LXC    < <(state_list lxc)
mapfile -t S_VM     < <(state_list vm)
mapfile -t S_POOL   < <(state_list pool)
mapfile -t S_USER   < <(state_list user)
mapfile -t S_ROLE   < <(state_list role)
mapfile -t S_ZONE   < <(state_list zone)
mapfile -t S_VNET   < <(state_list vnet)
mapfile -t S_SUBNET < <(state_list subnet)
MGMT_CT="${S_LXC[0]:-$CTID}"

# Guests in this environment's pools that the environment did not create itself
# (lab nodes made by OpenTofu, for example)
OWN_IDS=" ${S_LXC[*]} ${S_VM[*]} "
GUESTS=()
for p in "${S_POOL[@]}"; do
  while read -r type vmid name; do
    if [[ -n "$vmid" && "$OWN_IDS" != *" ${vmid} "* ]]; then GUESTS+=("${type} ${vmid} ${name} (pool ${p})"); fi
  done < <(pool_guests "$p")
done
if [[ ${#GUESTS[@]} -gt 0 && "$PURGE" != "1" ]]; then
  for g in "${GUESTS[@]}"; do warn "Still in use -> ${g}"; done
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "A real reset would stop here. Destroy those guests first, or use: dsoadm reset --env ${ENV_NAME} --purge"
  else
    die "Guests still exist in environment '${ENV_NAME}'. Destroy them first, or use: dsoadm reset --env ${ENV_NAME} --purge"
  fi
fi

# With --purge --sdn: other vnets inside this environment's zone (made by OpenTofu)
OTHER_VNETS=()
if [[ "$PURGE" == "1" && "$RESET_SDN" == "1" && ${#S_ZONE[@]} -gt 0 ]]; then
  for z in "${S_ZONE[@]}"; do
    while read -r v; do
      if [[ -n "$v" && " ${S_VNET[*]} " != *" ${v} "* ]]; then OTHER_VNETS+=("$v"); fi
    done < <(pvesh get /cluster/sdn/vnets --output-format json | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    if v.get("zone") == sys.argv[1]:
        print(v["vnet"])' "$z")
  done
fi

echo
echo "Environment '${ENV_NAME}' — this will remove:"
if [[ "$PURGE" == "1" && ${#GUESTS[@]} -gt 0 ]]; then
  echo "  - Guests in its pools:"
  for g in "${GUESTS[@]}"; do echo "      ${g}"; done
  if [[ -n "$TEARDOWN_CMD" ]]; then echo "    (first through '${TEARDOWN_CMD}' inside LXC ${MGMT_CT}, then directly)"; fi
fi
for x in "${S_LXC[@]}"; do echo "  - Management LXC ${x}"; done
for x in "${S_VM[@]}";  do echo "  - VM template ${x}"; done
if [[ ${#S_POOL[@]} -gt 0 ]]; then echo "  - Pools ${S_POOL[*]} (if empty)"; fi
for x in "${S_USER[@]}"; do echo "  - API user ${x} (with its tokens and ACLs)"; done
if [[ ${#S_ROLE[@]} -gt 0 ]]; then echo "  - Roles ${S_ROLE[*]}"; fi
if [[ "$RESET_SDN" == "1" ]]; then
  if [[ ${#OTHER_VNETS[@]} -gt 0 ]]; then echo "  - Other vnets in its zone: ${OTHER_VNETS[*]}"; fi
  if [[ ${#S_SUBNET[@]} -gt 0 ]]; then echo "  - SDN subnets ${S_SUBNET[*]}"; fi
  if [[ ${#S_VNET[@]} -gt 0 ]]; then echo "  - SDN vnets ${S_VNET[*]}"; fi
  if [[ ${#S_ZONE[@]} -gt 0 ]]; then echo "  - SDN zone ${S_ZONE[*]} (if no other vnets remain)"; fi
fi
echo "Kept: settings (${CONFIG_FILE}), other environments, downloaded images"
if [[ "$RESET_SDN" != "1" && $(( ${#S_ZONE[@]} + ${#S_VNET[@]} + ${#S_SUBNET[@]} )) -gt 0 ]]; then
  echo "Kept: SDN network (add --sdn to remove it)"
fi
if [[ "$DRY_RUN" == "1" ]]; then echo "  (dry-run: nothing will actually be removed)"; fi
echo

if [[ "$DRY_RUN" != "1" && "$FORCE" != "1" ]]; then
  read -r -p "Type the environment name '${ENV_NAME}' to confirm: " answer
  [[ "$answer" == "$ENV_NAME" ]] || die "Confirmation did not match. Aborted."
fi

# =============================================================
# 1. Purge: guests in the environment's pools
# =============================================================
destroy_guest() {  # destroy_guest <lxc|qemu> <vmid> <name>
  local tool=pct
  if [[ "$1" == "qemu" ]]; then tool=qm; fi
  if "$tool" status "$2" 2>/dev/null | grep -q running; then
    log "Stopping ${1} ${2} (${3})"
    run "$tool" stop "$2"
  fi
  log "Destroying ${1} ${2} (${3})"
  run "$tool" destroy "$2" --purge 1
}

if [[ "$PURGE" == "1" && ${#GUESTS[@]} -gt 0 ]]; then
  if [[ -n "$TEARDOWN_CMD" ]]; then
    if pct status "$MGMT_CT" 2>/dev/null | grep -q running; then
      log "Running in LXC ${MGMT_CT}: ${TEARDOWN_CMD}"
      if [[ "$DRY_RUN" == "1" ]]; then
        run pct exec "$MGMT_CT" -- bash -lc "$TEARDOWN_CMD"
      elif ! pct exec "$MGMT_CT" -- bash -lc "$TEARDOWN_CMD"; then
        die "'${TEARDOWN_CMD}' failed or was cancelled. Nothing else was removed."
      fi
    else
      warn "LXC ${MGMT_CT} is not running; skipping '${TEARDOWN_CMD}'"
    fi
  fi
  # Whatever is still there (or everything, without TEARDOWN_CMD)
  for p in "${S_POOL[@]}"; do
    while read -r type vmid name; do
      if [[ -n "$vmid" && "$OWN_IDS" != *" ${vmid} "* ]]; then destroy_guest "$type" "$vmid" "$name"; fi
    done < <(pool_guests "$p")
  done
fi

# =============================================================
# 2. Management LXC and VM template (checked before removal)
# =============================================================
for id in "${S_LXC[@]}"; do
  if ! pct status "$id" &>/dev/null; then
    log "LXC ${id} already gone"; gone lxc "$id"; continue
  fi
  if [[ "$(pct config "$id" | awk '/^tags:/ {print $2}')" != *"env-${ENV_NAME}"* ]]; then
    warn "LXC ${id} is not tagged env-${ENV_NAME} -> not touching it"; continue
  fi
  if pct status "$id" | grep -q running; then log "Stopping LXC ${id}"; run pct stop "$id"; fi
  log "Destroying LXC ${id}"
  run pct destroy "$id" --purge 1
  gone lxc "$id"
done

for id in "${S_VM[@]}"; do
  if ! qm status "$id" &>/dev/null; then
    log "VM ${id} already gone"; gone vm "$id"; continue
  fi
  if [[ "$(qm config "$id" | awk '/^tags:/ {print $2}')" != *"env-${ENV_NAME}"* ]]; then
    warn "VM ${id} is not tagged env-${ENV_NAME} -> not touching it"; continue
  fi
  log "Destroying VM template ${id}"
  run qm destroy "$id" --purge 1
  gone vm "$id"
done

# =============================================================
# 3. Pools
# =============================================================
for pool in "${S_POOL[@]}"; do
  if ! pvesh get /pools --output-format json | json_has poolid "$pool"; then
    gone pool "$pool"; continue
  fi
  comment=$(pvesh get /pools --output-format json | json_get poolid "$pool" comment)
  if [[ "$comment" != *"$PROJECT_MARKER"* ]]; then
    warn "Pool '${pool}' has no ${PROJECT_MARKER} marker -> not touching it"; continue
  fi
  members=$(pool_guests "$pool" | wc -l)
  if [[ "$members" != "0" && "$DRY_RUN" != "1" ]]; then
    warn "Pool '${pool}' still has ${members} member(s) -> not removing"; continue
  fi
  log "Removing pool '${pool}'"
  run pvesh delete "/pools/${pool}"
  gone pool "$pool"
done

# =============================================================
# 4. API user, roles
# =============================================================
for u in "${S_USER[@]}"; do
  if pveum user list --output-format json | json_has userid "$u"; then
    log "Removing user '${u}' (tokens and ACLs included)"
    run pveum user delete "$u"
  fi
  gone user "$u"
done

for r in "${S_ROLE[@]}"; do
  if pveum role list --output-format json | json_has roleid "$r"; then
    log "Removing role '${r}'"
    run pveum role delete "$r"
  fi
  gone role "$r"
done

# =============================================================
# 5. SDN (only with RESET_SDN=1)
# =============================================================
if [[ "$RESET_SDN" == "1" ]]; then
  ALL_VNETS=("${OTHER_VNETS[@]}" "${S_VNET[@]}")
  ATTACHED=""
  for v in "${ALL_VNETS[@]}"; do
    hits=$(grep -lE "bridge=${v}([,[:space:]]|$)" \
        /etc/pve/nodes/*/lxc/*.conf /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null || true)
    if [[ -n "$hits" ]]; then ATTACHED+="${hits}"$'\n'; fi
  done
  ATTACHED="${ATTACHED%$'\n'}"
  if [[ -n "$ATTACHED" && "$DRY_RUN" != "1" ]]; then
    warn "Guests still use this environment's network, keeping SDN:"
    while read -r conf; do echo "    ${conf}"; done <<< "$ATTACHED"
  else
    SDN_CHANGED=0
    for v in "${OTHER_VNETS[@]}"; do
      while read -r sid; do
        if [[ -n "$sid" ]]; then log "Removing SDN subnet '${sid}'"; run pvesh delete "/cluster/sdn/vnets/${v}/subnets/${sid}"; fi
      done < <(pvesh get "/cluster/sdn/vnets/${v}/subnets" --output-format json \
                 | python3 -c 'import json, sys; [print(d["subnet"]) for d in json.load(sys.stdin)]')
      log "Removing SDN vnet '${v}'"
      run pvesh delete "/cluster/sdn/vnets/${v}"
      SDN_CHANGED=1
    done
    for s in "${S_SUBNET[@]}"; do      # stored as <vnet>/<subnet id>
      log "Removing SDN subnet '${s#*/}'"
      run pvesh delete "/cluster/sdn/vnets/${s%%/*}/subnets/${s#*/}" || true
      gone subnet "$s"; SDN_CHANGED=1
    done
    for v in "${S_VNET[@]}"; do
      if pvesh get /cluster/sdn/vnets --output-format json | json_has vnet "$v"; then
        log "Removing SDN vnet '${v}'"
        run pvesh delete "/cluster/sdn/vnets/${v}"
        SDN_CHANGED=1
      fi
      gone vnet "$v"
    done
    for z in "${S_ZONE[@]}"; do
      remaining=$(pvesh get /cluster/sdn/vnets --output-format json | python3 -c '
import json, sys
zone, skip = sys.argv[1], sys.argv[2].split()
print(sum(1 for v in json.load(sys.stdin) if v.get("zone") == zone and v.get("vnet") not in skip))' \
        "$z" "${ALL_VNETS[*]}")
      if [[ "$remaining" != "0" ]]; then
        warn "Zone '${z}' still has ${remaining} other vnet(s) -> keeping it (remove them, or use --purge)"
        continue
      fi
      log "Removing SDN zone '${z}'"
      run pvesh delete "/cluster/sdn/zones/${z}"
      gone zone "$z"; SDN_CHANGED=1
    done
    if [[ $SDN_CHANGED -eq 1 ]]; then
      log "Applying SDN configuration"
      run pvesh set /cluster/sdn
    fi
  fi
fi

echo
if [[ "$DRY_RUN" == "1" ]]; then
  log "Dry run complete. Nothing was removed."
elif [[ -f "$STATE_FILE" ]]; then
  log "Reset of '${ENV_NAME}' done. Still recorded (kept on purpose): $(tr '\n' ' ' < "$STATE_FILE")"
else
  log "Reset of '${ENV_NAME}' complete. Run 'dsoadm init --env ${ENV_NAME}' to build it again."
fi
