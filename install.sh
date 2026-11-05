#!/usr/bin/env bash
# =============================================================
# install.sh — entry point for proxmox-iac-bootstrap
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
#
# What it does, in order:
#   1) Checks: Proxmox VE host, root, required commands
#   2) Asks for settings (Default / Advanced) -> /etc/proxmox-iac-bootstrap/bootstrap.env
#   3) Downloads one release archive (+ SHA256SUMS) into a temp folder and verifies it
#   4) Installs to /usr/local/lib/proxmox-iac-bootstrap, links /usr/local/sbin/dsoadm
#   5) Runs `dsoadm init`
#
# Environment (all optional):
#   PIB_REF=latest|vX.Y.Z|main   What to install (default: latest release)
#   PIB_YES=1                    No questions: defaults, or the existing config
#   PIB_NO_INIT=1                Install dsoadm only, do not run init
#   PIB_REPO=owner/name          Install from a fork
#   PIB_SRC=/path/to/checkout    Install from a local folder instead of GitHub (development)
# Re-run  : Safe. Replaces the installed files; keeps your config.
# =============================================================
set -euo pipefail

PIB_REPO="${PIB_REPO:-combatreadiness/proxmox-iac-bootstrap}"
PIB_REF="${PIB_REF:-latest}"
PIB_YES="${PIB_YES:-0}"
PIB_NO_INIT="${PIB_NO_INIT:-0}"
PIB_SRC="${PIB_SRC:-}"

NAME="proxmox-iac-bootstrap"
LIB_DIR="/usr/local/lib/${NAME}"
BIN_LINK="/usr/local/sbin/dsoadm"
ETC_DIR="/etc/${NAME}"
CONFIG="${ETC_DIR}/bootstrap.env"
REQUIRED_FILES=(
  bootstrap/dsoadm bootstrap/pve-host.sh bootstrap/mgmt-node.sh
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
   ┌─────────────────────────────────────────────┐
   │   Proxmox IaC Bootstrap                     │
   │   SDN · management LXC · OpenTofu · Ansible │
   └─────────────────────────────────────────────┘
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

ask() {  # ask <label> <default>
  local answer=""
  if [[ $USE_WT -eq 1 ]]; then
    answer=$(wt --title "Advanced settings" --inputbox "$1" 9 64 "$2") || return 1
  else
    read -r -p "    $1 [$2]: " answer </dev/tty || true
    answer="${answer:-$2}"
  fi
  printf '%s' "$answer"
}

yesno() {  # yesno <title> <text>  -> exit 0 on yes
  local answer=""
  if [[ $USE_WT -eq 1 ]]; then
    whiptail --backtitle "$TITLE" --title "$1" --yesno "$2" 22 72 </dev/tty
  else
    echo "$2" | sed 's/^/    /'
    read -r -p "    $1 [Y/n]: " answer </dev/tty || true
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
  fi
}

# ---------- Settings: names, defaults, labels ----------
# Asked in this order: the network first, so the gateway and the LXC address
# can be filled in from the subnet
KEYS=(SDN_ZONE SDN_VNET SDN_SUBNET SDN_GATEWAY CT_IP CTID CT_HOSTNAME
      CT_STORAGE TMPL_STORAGE POOL_PREFIX OP_POOLS SSH_PUBKEY_FILE REPO_URL)
declare -A DEF=(
  [CTID]=200 [CT_HOSTNAME]=iac-mgmt [CT_IP]=10.73.10.10/24
  [SDN_ZONE]=lab [SDN_VNET]=lmgmt [SDN_SUBNET]=10.73.10.0/24 [SDN_GATEWAY]=10.73.10.1
  [CT_STORAGE]=local-lvm [TMPL_STORAGE]=local [POOL_PREFIX]=lab [OP_POOLS]=workloads
  [SSH_PUBKEY_FILE]=/root/.ssh/authorized_keys [REPO_URL]=""
)
declare -A LABEL=(
  [CTID]="Management LXC ID" [CT_HOSTNAME]="Management LXC hostname"
  [CT_IP]="Management LXC IP/CIDR (filled in from the subnet)" [SDN_ZONE]="SDN zone"
  [SDN_VNET]="SDN vnet (8 characters max)" [SDN_SUBNET]="Management subnet"
  [SDN_GATEWAY]="Gateway (this host on that subnet; filled in from the subnet)"
  [CT_STORAGE]="Storage for the LXC disk" [TMPL_STORAGE]="Storage for templates"
  [POOL_PREFIX]="Pool prefix"
  [OP_POOLS]="Pools OpenTofu may use, space-separated (e.g. tools k8s)" [SSH_PUBKEY_FILE]="SSH public keys to copy into the LXC"
  [REPO_URL]="Git repository to clone on the LXC (empty = none)"
)
declare -A VAL=()

summary() {
  local k
  for k in "${KEYS[@]}"; do printf '%-16s %s\n' "$k" "${VAL[$k]:-(empty)}"; done
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
echo; echo "${DIM}  Settings${CL}"
# =============================================================
install -d -m 700 "$ETC_DIR"

# Current values: the existing config wins over the defaults
for k in "${KEYS[@]}"; do VAL[$k]="${DEF[$k]}"; done
if [[ -f "$CONFIG" ]]; then
  while IFS='=' read -r k v; do
    k="${k//[[:space:]]/}"
    if [[ -n "$k" && -v "DEF[$k]" ]]; then
      v="${v%%#*}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      VAL[$k]="$v"
    fi
  done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG")
fi

# net_addr <cidr> <n>  -> host number n in that subnet ("" if the subnet is invalid)
#   net_addr 10.70.10.0/24 1  -> 10.70.10.1      net_addr 10.70.10.0/24 10/ -> 10.70.10.10/24
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

edit_settings() {  # one input box per setting, prefilled with the current value
  local k v old_gw old_ip
  for k in "${KEYS[@]}"; do
    while :; do
      v=$(ask "${LABEL[$k]}" "${VAL[$k]}") || msg_err "Cancelled. Nothing was changed."
      if [[ "$k" != "SDN_SUBNET" || -n "$(net_addr "$v" 1)" ]]; then break; fi
      echo "    Not a subnet: ${v} (example: 10.70.10.0/24)"
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

# Write KEYS into the config; other lines (comments, TEARDOWN_CMD, ...) are kept
save_settings() {
  local tmp k done_keys=" "
  # mktemp makes the file 0600. No umask change here: it would leak into
  # `dsoadm init`, and pct cannot create unprivileged containers under umask 077.
  tmp="$(mktemp "${ETC_DIR}/.bootstrap.env.XXXXXX")"
  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      k="${line%%=*}"; k="${k//[[:space:]]/}"
      if [[ "$line" == *=* && -v "DEF[$k]" ]]; then
        echo "${k}=${VAL[$k]}"; done_keys+="${k} "
      else
        echo "$line"
      fi
    done < "$CONFIG" > "$tmp"
  else
    {
      echo "# Written by install.sh on $(date -u +%Y-%m-%dT%H:%MZ)."
      echo "# All keys and defaults: ${LIB_DIR}/bootstrap/bootstrap.env.example"
    } > "$tmp"
  fi
  for k in "${KEYS[@]}"; do
    if [[ "$done_keys" != *" ${k} "* ]]; then echo "${k}=${VAL[$k]}" >> "$tmp"; fi
  done
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
}

if [[ -f "$CONFIG" && ( $INTERACTIVE -eq 0 || "$PIB_NO_INIT" == "1" ) ]]; then
  # Updating only, or no one to ask: keep the file as it is
  msg_ok "Using ${CONFIG}"
elif [[ -f "$CONFIG" ]]; then
  if yesno "Existing settings" "Found ${CONFIG}:

$(summary)

Yes = use these.  No = change them."; then
    msg_ok "Using ${CONFIG}"
  else
    edit_settings
    yesno "Ready" "These settings will be used:

$(summary)

Continue?" || msg_err "Cancelled. Nothing was changed."
    save_settings
    msg_ok "Updated ${CONFIG}"
  fi
else
  if [[ $INTERACTIVE -eq 1 ]]; then
    mode="default"
    if [[ $USE_WT -eq 1 ]]; then
      mode=$(wt --title "Settings" --menu "How do you want to set this up?" 12 64 2 \
        default "Default settings" advanced "Advanced settings") || msg_err "Cancelled."
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
  [[ -f "src/$f" ]] || msg_err "Archive is missing ${f}."
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
msg_ok "Installed ${LIB_DIR}"
msg_ok "Linked ${BIN_LINK}"

# =============================================================
echo; echo "${DIM}  dsoadm init${CL}"
# =============================================================
if [[ "$PIB_NO_INIT" == "1" ]]; then
  msg_skip "Skipped (PIB_NO_INIT=1). Run it yourself: dsoadm init"
  exit 0
fi
cd /
"$BIN_LINK" init || msg_err "dsoadm init failed. Fix the error above and run: dsoadm init"

echo
echo "  ${GN}Done.${CL} Manage it later with: ${BL}dsoadm help${CL}"
