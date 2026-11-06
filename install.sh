#!/usr/bin/env bash
# =============================================================
# install.sh — entry point for proxmox-iac-bootstrap
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
#
# What it does, in order:
#   1) Checks: Proxmox VE host, root, required commands
#   2) Downloads one release archive (+ SHA256SUMS) into a temp folder and verifies it
#   3) Installs to /usr/local/lib/proxmox-iac-bootstrap, links /usr/local/sbin/dsoadm
#   4) Environment name + settings (Default / Advanced) -> /etc/proxmox-iac-bootstrap/envs/<name>.env
#   5) Runs `dsoadm init --env <name>`
#
# Environment (all optional):
#   PIB_ENV=name                 Environment to create or update (default: lab)
#   PIB_REF=latest|vX.Y.Z|main   What to install (default: latest release)
#   PIB_YES=1                    No questions: defaults, or the existing settings
#   PIB_NO_INIT=1                Install dsoadm (and write settings) only, do not run init
#   PIB_REPO=owner/name          Install from a fork
#   PIB_SRC=/path/to/checkout    Install from a local folder instead of GitHub (development)
#   Any setting (CTID=300, SDN_SUBNET=...) is written into the settings file too.
# Re-run  : Safe. Replaces the installed files; keeps your settings.
# =============================================================
set -euo pipefail

PIB_REPO="${PIB_REPO:-combatreadiness/proxmox-iac-bootstrap}"
PIB_REF="${PIB_REF:-latest}"
PIB_YES="${PIB_YES:-0}"
PIB_NO_INIT="${PIB_NO_INIT:-0}"
PIB_SRC="${PIB_SRC:-}"
PIB_ENV="${PIB_ENV:-}"

NAME="proxmox-iac-bootstrap"
LIB_DIR="/usr/local/lib/${NAME}"
BIN_LINK="/usr/local/sbin/dsoadm"
ETC_DIR="/etc/${NAME}"
ENVS_DIR="${ETC_DIR}/envs"
REQUIRED_FILES=(
  bootstrap/dsoadm bootstrap/lib.sh bootstrap/pve-host.sh bootstrap/mgmt-node.sh
  bootstrap/pve-facts.sh bootstrap/pve-template.sh bootstrap/pve-reset.sh
  bootstrap/bootstrap.env.example
)
TITLE="Proxmox IaC Bootstrap"

# ---------- Output ----------
GN=$'\e[1;32m'; YW=$'\e[1;33m'; RD=$'\e[1;31m'; BL=$'\e[1;36m'; DIM=$'\e[2m'; CL=$'\e[0m'
msg_info() { printf '  %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K  %s✔%s %s\n' "$GN" "$CL" "$1"; }
msg_skip() { printf '\r\e[K  %s–%s %s\n' "$YW" "$CL" "$1"; }
msg_err()  { printf '\r\e[K  %s✖%s %s\n' "$RD" "$CL" "$1" >&2; exit 1; }

header() {
  clear 2>/dev/null || true
  cat <<EOF
${BL}
   ┌──────────────────────────────────────────────┐
   │   Proxmox IaC Bootstrap                      │
   │   SDN · least-privilege API · OpenTofu node  │
   └──────────────────────────────────────────────┘
${CL}
EOF
}

TMP=""
cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
INTERACTIVE=0
if [[ "$PIB_YES" != "1" && $HAVE_TTY -eq 1 ]]; then INTERACTIVE=1; fi
USE_WT=0
if [[ $INTERACTIVE -eq 1 ]] && command -v whiptail >/dev/null; then USE_WT=1; fi

# ---------- Questions (whiptail when available, plain prompts otherwise) ----------
wt() { whiptail --backtitle "$TITLE" "$@" 3>&1 1>&2 2>&3 </dev/tty; }

ask() {  # ask <title> <label> <default>
  local answer=""
  if [[ $USE_WT -eq 1 ]]; then
    answer=$(wt --title "$1" --inputbox "$2" 9 70 "$3") || return 1
  else
    read -r -p "    $2 [$3]: " answer </dev/tty || true
    answer="${answer:-$3}"
  fi
  printf '%s' "$answer"
}

yesno() {  # yesno <title> <text>  -> exit 0 on yes
  local answer=""
  if [[ $USE_WT -eq 1 ]]; then
    whiptail --backtitle "$TITLE" --title "$1" --yesno "$2" 24 74 </dev/tty
  else
    echo "$2" | sed 's/^/    /'
    read -r -p "    $1 [Y/n]: " answer </dev/tty || true
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
  fi
}

header

# =============================================================
echo "${DIM}  Host${CL}"
# =============================================================
[[ $EUID -eq 0 ]] || msg_err "Run as root."
command -v pveversion >/dev/null || msg_err "This is not a Proxmox VE host (pveversion not found)."
msg_ok "$(pveversion)"
for c in curl tar gzip sha256sum python3 pvesh pveum pct pveam; do
  command -v "$c" >/dev/null || msg_err "Missing command: $c"
done
msg_ok "Required commands present"
[[ "$PIB_REPO" != *"<OWNER>"* ]] || msg_err "PIB_REPO is not set (this copy of install.sh still has the <OWNER> placeholder)."

# =============================================================
echo; echo "${DIM}  Download${CL}"
# =============================================================
TMP="$(mktemp -d)"
cd "$TMP"

fetch() {  # fetch <url> <file>
  curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -o "$2" "$1" \
    || msg_err "Download failed: $1"
}

if [[ -n "$PIB_SRC" ]]; then
  # Local checkout: no download, no checksum
  [[ -d "$PIB_SRC" ]] || msg_err "PIB_SRC is not a folder: ${PIB_SRC}"
  mkdir src
  (cd "$PIB_SRC" && tar --exclude=.git -cf - .) | tar -xf - -C src
  TAG="local"
  if command -v git >/dev/null && git -C "$PIB_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
    TAG="local-$(git -C "$PIB_SRC" rev-parse --short HEAD)"
  fi
  echo "$TAG" > src/VERSION
  msg_skip "Using local folder ${PIB_SRC} (${TAG}), no checksum"
else
  msg_info "Finding release"
  if [[ "$PIB_REF" == "latest" ]]; then
    url=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' \
          "https://github.com/${PIB_REPO}/releases/latest") \
      || msg_err "Cannot reach GitHub to find the latest release."
    TAG="${url##*/}"
    [[ "$TAG" == v* ]] || msg_err "No release found for ${PIB_REPO}. Use PIB_REF=main to install from the branch."
  else
    TAG="$PIB_REF"
  fi
  msg_ok "${PIB_REPO} ${TAG}"

  if [[ "$TAG" == v* ]]; then
    ARCHIVE="${NAME}-${TAG}.tar.gz"
    base="https://github.com/${PIB_REPO}/releases/download/${TAG}"
    msg_info "Downloading ${ARCHIVE}"
    fetch "${base}/${ARCHIVE}" "$ARCHIVE"
    fetch "${base}/SHA256SUMS" SHA256SUMS
    msg_ok "Downloaded ${ARCHIVE}"
    line=$(grep -E "  ${ARCHIVE}\$" SHA256SUMS || true)
    [[ -n "$line" ]] || msg_err "${ARCHIVE} is not listed in SHA256SUMS."
    echo "$line" | sha256sum -c --quiet - >/dev/null 2>&1 || msg_err "Checksum mismatch for ${ARCHIVE}."
    msg_ok "SHA256 verified"
  else
    # Branch or commit: no published checksum. Meant for testing.
    ARCHIVE="${NAME}-src.tar.gz"
    msg_info "Downloading ${TAG}"
    fetch "https://github.com/${PIB_REPO}/archive/${TAG}.tar.gz" "$ARCHIVE"
    msg_skip "No checksum for a branch build (${TAG}); use a release for normal installs"
  fi
  mkdir src
  tar -xzf "$ARCHIVE" -C src --strip-components=1 || msg_err "Cannot extract ${ARCHIVE}."
fi

for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "src/$f" ]] || msg_err "Archive is missing ${f}. This installer needs v0.2.0 or later; for an older release use the install.sh from that release's tag."
done
[[ -f src/VERSION ]] || echo "${TAG}" > src/VERSION
msg_ok "All files present"

# =============================================================
echo; echo "${DIM}  Install${CL}"
# =============================================================
chmod 755 src/bootstrap/dsoadm src/bootstrap/*.sh
rm -rf "${LIB_DIR}.new"
mkdir -p "$(dirname "$LIB_DIR")"
cp -a src "${LIB_DIR}.new"
chown -R root:root "${LIB_DIR}.new"
if [[ -d "$LIB_DIR" ]]; then
  rm -rf "${LIB_DIR}.old"
  mv "$LIB_DIR" "${LIB_DIR}.old"
fi
mv "${LIB_DIR}.new" "$LIB_DIR"
rm -rf "${LIB_DIR}.old"
ln -sfn "${LIB_DIR}/bootstrap/dsoadm" "$BIN_LINK"
msg_ok "Installed ${LIB_DIR} ($(cat "${LIB_DIR}/VERSION"))"
msg_ok "Linked ${BIN_LINK}"
cd /
"$BIN_LINK" list >/dev/null || true   # Moves a v0.1 settings file into envs/lab.env, if there is one

# =============================================================
echo; echo "${DIM}  Environment and settings${CL}"
# =============================================================
# Asked in this order: the network first, so the gateway and the LXC address follow the subnet
KEYS=(SDN_ZONE SDN_VNET SDN_SUBNET SDN_GATEWAY CT_IP CTID CT_HOSTNAME
      CT_STORAGE TMPL_STORAGE OP_POOLS SSH_PUBKEY_FILE REPO_URL)
declare -A LABEL=(
  [SDN_ZONE]="SDN zone"
  [SDN_VNET]="SDN vnet ID (8 characters max, letters and digits)"
  [SDN_SUBNET]="Management subnet"
  [SDN_GATEWAY]="Gateway (this host on that subnet; follows the subnet)"
  [CT_IP]="Management LXC IP/CIDR (follows the subnet)"
  [CTID]="Management LXC ID"
  [CT_HOSTNAME]="Management LXC hostname"
  [CT_STORAGE]="Storage for the LXC disk"
  [TMPL_STORAGE]="Storage for templates"
  [OP_POOLS]="Pools OpenTofu may use, space-separated (e.g. tools k8s)"
  [SSH_PUBKEY_FILE]="SSH public keys to copy into the LXC"
  [REPO_URL]="Git repository to clone on the LXC (empty = none)"
)
declare -A VAL=()

summary() {
  local k
  printf '%-16s %s\n' ENVIRONMENT "$PIB_ENV"
  for k in "${KEYS[@]}"; do printf '%-16s %s\n' "$k" "${VAL[$k]:-(empty)}"; done
}

# net_addr <cidr> <n>  -> host n of the subnet; <n>/ adds the prefix length ("" if invalid)
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

# ----- Which environment -----
mapfile -t EXISTING < <(for f in "${ENVS_DIR}"/*.env; do if [[ -f "$f" ]]; then f="${f##*/}"; echo "${f%.env}"; fi; done)
if [[ -z "$PIB_ENV" ]]; then
  if [[ ${#EXISTING[@]} -eq 0 ]]; then default_env=lab; else default_env="${EXISTING[0]}"; fi
  if [[ $INTERACTIVE -eq 1 ]]; then
    hint="Existing: ${EXISTING[*]:-none}. Type a new name to add another environment."
    PIB_ENV=$(ask "Environment" "Environment name (1-6 lowercase letters/digits). ${hint}" "$default_env") \
      || msg_err "Cancelled. Nothing was changed."
  else
    PIB_ENV="$default_env"
  fi
fi
[[ "$PIB_ENV" =~ ^[a-z][a-z0-9]{0,5}$ ]] || msg_err "Environment name '${PIB_ENV}': 1-6 lowercase letters/digits, starting with a letter."
CONFIG="${ENVS_DIR}/${PIB_ENV}.env"

# ----- Current values: existing file, else free values picked by dsoadm -----
if [[ -f "$CONFIG" ]]; then SOURCE_LINES=$(cat "$CONFIG"); else SOURCE_LINES=$("$BIN_LINK" _suggest --env "$PIB_ENV"); fi
while IFS='=' read -r k v; do
  k="${k//[[:space:]]/}"
  if [[ -n "$k" && -v "LABEL[$k]" ]]; then
    v="${v%%#*}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    VAL[$k]="$v"
  fi
done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' <<<"$SOURCE_LINES")
if [[ -f "$CONFIG" ]]; then
  # Keys an older file may lack
  while IFS='=' read -r k v; do
    if [[ -z "${VAL[$k]+x}" ]]; then VAL[$k]="$v"; fi
  done < <("$BIN_LINK" _suggest --env "$PIB_ENV")
fi
# Settings passed on the command line (CTID=300 bash install.sh) win, and are saved
OVERRIDDEN=0
OLD_GW=$(net_addr "${VAL[SDN_SUBNET]}" 1); OLD_IP=$(net_addr "${VAL[SDN_SUBNET]}" 10/)
for k in "${KEYS[@]}"; do
  if [[ -n "${!k+x}" ]]; then VAL[$k]="${!k}"; OVERRIDDEN=1; fi
done
# A new subnet moves the gateway and LXC address along, unless those were given too or set by hand
if [[ -n "${SDN_SUBNET+x}" ]]; then
  [[ -n "$(net_addr "$SDN_SUBNET" 1)" ]] || msg_err "SDN_SUBNET '${SDN_SUBNET}' is not a subnet."
  if [[ -z "${SDN_GATEWAY+x}" && "${VAL[SDN_GATEWAY]}" == "$OLD_GW" ]]; then VAL[SDN_GATEWAY]=$(net_addr "$SDN_SUBNET" 1); fi
  if [[ -z "${CT_IP+x}" && "${VAL[CT_IP]}" == "$OLD_IP" ]]; then VAL[CT_IP]=$(net_addr "$SDN_SUBNET" 10/); fi
fi

edit_settings() {  # one input box per setting, prefilled with the current value
  local k v old_gw old_ip
  for k in "${KEYS[@]}"; do
    while :; do
      v=$(ask "Advanced settings · ${PIB_ENV}" "${LABEL[$k]}" "${VAL[$k]}") || msg_err "Cancelled. Nothing was changed."
      case "$k" in
        SDN_SUBNET) [[ -n "$(net_addr "$v" 1)" ]] && break; echo "    Not a subnet: ${v} (example: 10.70.10.0/24)" ;;
        SDN_VNET)   [[ "$v" =~ ^[a-z][a-z0-9]{0,7}$ ]] && break; echo "    VNet ID: 8 characters max, lowercase letters and digits" ;;
        CTID)       [[ "$v" =~ ^[0-9]+$ ]] && break; echo "    Not a number: ${v}" ;;
        *) break ;;
      esac
    done
    if [[ "$k" == "SDN_SUBNET" && "$v" != "${VAL[SDN_SUBNET]}" ]]; then
      # Gateway and LXC address follow the subnet unless they were set by hand
      old_gw=$(net_addr "${VAL[SDN_SUBNET]}" 1); old_ip=$(net_addr "${VAL[SDN_SUBNET]}" 10/)
      if [[ "${VAL[SDN_GATEWAY]}" == "$old_gw" ]]; then VAL[SDN_GATEWAY]=$(net_addr "$v" 1); fi
      if [[ "${VAL[CT_IP]}" == "$old_ip" ]]; then VAL[CT_IP]=$(net_addr "$v" 10/); fi
    fi
    VAL[$k]="$v"
  done
}

# Write KEYS into the settings file; other lines (comments, TEARDOWN_CMD, ...) are kept
save_settings() {
  local tmp k line done_keys=" "
  install -d -m 700 "$ENVS_DIR"
  # mktemp makes the file 0600. No umask change here: it would leak into
  # `dsoadm init`, and pct cannot create unprivileged containers under umask 077.
  tmp="$(mktemp "${ENVS_DIR}/.${PIB_ENV}.env.XXXXXX")"
  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      k="${line%%=*}"; k="${k//[[:space:]]/}"
      if [[ "$line" == *=* && -v "LABEL[$k]" ]]; then
        echo "${k}=${VAL[$k]}"; done_keys+="${k} "
      else
        echo "$line"
      fi
    done < "$CONFIG" > "$tmp"
  else
    {
      echo "# Environment ${PIB_ENV}, written by install.sh on $(date -u +%Y-%m-%dT%H:%MZ)."
      echo "# All keys and defaults: ${LIB_DIR}/bootstrap/bootstrap.env.example"
    } > "$tmp"
  fi
  for k in "${KEYS[@]}"; do
    if [[ "$done_keys" != *" ${k} "* ]]; then echo "${k}=${VAL[$k]}" >> "$tmp"; fi
  done
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
}

if [[ -f "$CONFIG" && $INTERACTIVE -eq 0 ]]; then
  if [[ $OVERRIDDEN -eq 1 ]]; then save_settings; msg_ok "Updated ${CONFIG} (values given on the command line)"; else msg_ok "Using ${CONFIG}"; fi
elif [[ -f "$CONFIG" && "$PIB_NO_INIT" == "1" ]]; then
  msg_ok "Using ${CONFIG}"
elif [[ -f "$CONFIG" ]]; then
  if yesno "Environment ${PIB_ENV}" "Found ${CONFIG}:

$(summary)

Yes = use these.  No = change them."; then
    if [[ $OVERRIDDEN -eq 1 ]]; then save_settings; fi
    msg_ok "Using ${CONFIG}"
  else
    edit_settings
    yesno "Ready" "These settings will be used:

$(summary)

Continue?" || msg_err "Cancelled. Settings were not changed."
    save_settings
    msg_ok "Updated ${CONFIG}"
  fi
else
  if [[ $INTERACTIVE -eq 1 ]]; then
    mode="default"
    if [[ $USE_WT -eq 1 ]]; then
      mode=$(wt --title "Environment ${PIB_ENV}" --menu "How do you want to set it up?" 12 64 2 \
        default "Default settings (free ID and subnet picked for you)" advanced "Advanced settings") \
        || msg_err "Cancelled. Nothing was changed."
    else
      read -r -p "    Use default settings? [Y/n]: " a </dev/tty || true
      if [[ -n "$a" && ! "$a" =~ ^[Yy] ]]; then mode="advanced"; fi
    fi
    if [[ "$mode" == "advanced" ]]; then edit_settings; fi
    yesno "Ready" "These settings will be used:

$(summary)

Continue?" || msg_err "Cancelled. Nothing was changed."
  fi
  save_settings
  msg_ok "Wrote ${CONFIG}"
fi

# =============================================================
echo; echo "${DIM}  dsoadm init --env ${PIB_ENV}${CL}"
# =============================================================
if [[ "$PIB_NO_INIT" == "1" ]]; then
  msg_skip "Skipped (PIB_NO_INIT=1). Review ${CONFIG}, then run: dsoadm init --env ${PIB_ENV}"
  exit 0
fi
# The settings are in the file now; do not let the command-line copies shadow later edits
for k in "${KEYS[@]}"; do unset "$k"; done
"$BIN_LINK" init --env "$PIB_ENV" || msg_err "dsoadm init failed. Fix the error above and run: dsoadm init --env ${PIB_ENV}"

echo
echo "  ${GN}Done.${CL} Manage it later with: ${BL}dsoadm list${CL}, ${BL}dsoadm help${CL}"
