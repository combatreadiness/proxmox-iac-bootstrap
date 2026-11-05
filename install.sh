#!/usr/bin/env bash
# =============================================================
# install.sh — entry point for proxmox-iac-bootstrap
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
#
# What it does, in order:
#   1) Checks: Proxmox VE host, root, required commands
#   2) Downloads one release archive (+ SHA256SUMS) into a temp folder
#   3) Verifies the checksum and that all files are there
#   4) Installs to /usr/local/lib/proxmox-iac-bootstrap, links /usr/local/sbin/dsoadm
#   5) Asks for settings (Enter keeps the default) -> /etc/proxmox-iac-bootstrap/bootstrap.env
#   6) Runs `dsoadm init`
#
# Environment (all optional):
#   PIB_REF=latest|vX.Y.Z|main   What to install (default: latest release)
#   PIB_YES=1                    Accept defaults / existing config without asking
#   PIB_NO_INIT=1                Install dsoadm only, do not run init
#   PIB_REPO=owner/name          Install from a fork
# Re-run  : Safe. Replaces the installed files; keeps your config.
# =============================================================
set -euo pipefail

PIB_REPO="${PIB_REPO:-combatreadiness/proxmox-iac-bootstrap}"
PIB_REF="${PIB_REF:-latest}"
PIB_YES="${PIB_YES:-0}"
PIB_NO_INIT="${PIB_NO_INIT:-0}"

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

STEP=0
step() { STEP=$((STEP + 1)); echo -e "\n\e[1;36m[${STEP}]\e[0m \e[1m$*\e[0m"; }
ok()   { echo -e "    \e[1;32mok\e[0m   $*"; }
skip() { echo -e "    \e[1;33mskip\e[0m $*"; }
die()  { echo -e "    \e[1;31mfail\e[0m $*" >&2; exit 1; }

TMP=""
cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

# Read a line from the terminal even when stdin is a pipe (curl ... | bash)
HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
ask() {  # ask <prompt> <default>  -> prints the answer
  local answer=""
  if [[ "$PIB_YES" == "1" || $HAVE_TTY -eq 0 ]]; then echo "$2"; return; fi
  read -r -p "    $1 [$2]: " answer </dev/tty || true
  echo "${answer:-$2}"
}
confirm() {  # confirm <prompt>  -> exit 0 on yes (default yes)
  local answer=""
  if [[ "$PIB_YES" == "1" ]]; then return 0; fi
  [[ $HAVE_TTY -eq 1 ]] || die "No terminal to ask on. Re-run with PIB_YES=1."
  read -r -p "    $1 [Y/n]: " answer </dev/tty || true
  [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

# =============================================================
step "Checking this host"
# =============================================================
[[ $EUID -eq 0 ]] || die "Run as root."
command -v pveversion >/dev/null || die "This is not a Proxmox VE host (pveversion not found)."
ok "$(pveversion)"
for c in curl tar gzip sha256sum python3 pvesh pveum pct pveam; do
  command -v "$c" >/dev/null || die "Missing command: $c"
done
ok "required commands present"
[[ "$PIB_REPO" != *"<OWNER>"* ]] || die "PIB_REPO is not set (this copy of install.sh still has the <OWNER> placeholder)."

# =============================================================
step "Downloading ${PIB_REPO} (${PIB_REF})"
# =============================================================
TMP="$(mktemp -d)"
cd "$TMP"

fetch() {  # fetch <url> <file>
  curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -o "$2" "$1" \
    || die "Download failed: $1"
}

if [[ "$PIB_REF" == "latest" ]]; then
  url=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' \
        "https://github.com/${PIB_REPO}/releases/latest") \
    || die "Cannot reach GitHub to find the latest release."
  TAG="${url##*/}"
  [[ "$TAG" == v* ]] || die "No release found for ${PIB_REPO}. Use PIB_REF=main to install from the branch."
else
  TAG="$PIB_REF"
fi

if [[ "$TAG" == v* ]]; then
  ARCHIVE="${NAME}-${TAG}.tar.gz"
  base="https://github.com/${PIB_REPO}/releases/download/${TAG}"
  fetch "${base}/${ARCHIVE}" "$ARCHIVE"
  fetch "${base}/SHA256SUMS" SHA256SUMS
  ok "release ${TAG}"
  line=$(grep -E "  ${ARCHIVE}\$" SHA256SUMS || true)
  [[ -n "$line" ]] || die "${ARCHIVE} is not listed in SHA256SUMS."
  echo "$line" | sha256sum -c --quiet - || die "Checksum mismatch for ${ARCHIVE}."
  ok "sha256 verified"
else
  # Branch or commit: no published checksum. Meant for testing.
  ARCHIVE="${NAME}-src.tar.gz"
  fetch "https://github.com/${PIB_REPO}/archive/${TAG}.tar.gz" "$ARCHIVE"
  skip "no checksum for a branch build (${TAG}); use a release for normal installs"
fi

mkdir src
tar -xzf "$ARCHIVE" -C src --strip-components=1 || die "Cannot extract ${ARCHIVE}."
for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "src/$f" ]] || die "Archive is missing ${f}."
done
[[ -f src/VERSION ]] || echo "${TAG}" > src/VERSION
ok "all files present ($(cat src/VERSION))"

# =============================================================
step "Installing dsoadm"
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
ok "${LIB_DIR}"
ok "${BIN_LINK} -> ${LIB_DIR}/bootstrap/dsoadm"

# =============================================================
step "Settings"
# =============================================================
install -d -m 700 "$ETC_DIR"
# The answers below are written out through ${!k}, which ShellCheck cannot follow
# shellcheck disable=SC2034
if [[ -f "$CONFIG" ]]; then
  echo "    Existing config: ${CONFIG}"
  grep -Ev '^[[:space:]]*(#|$)' "$CONFIG" | sed 's/^/      /' || true
  if confirm "Use this config?"; then
    ok "keeping ${CONFIG}"
  else
    die "Edit ${CONFIG} and run: dsoadm init"
  fi
else
  echo "    Press Enter to keep a default."
  CTID=$(ask "Management LXC ID" 200)
  CT_HOSTNAME=$(ask "Management LXC hostname" iac-mgmt)
  SDN_ZONE=$(ask "SDN zone" lab)
  SDN_VNET=$(ask "SDN vnet (max 8 chars)" lmgmt)
  SDN_SUBNET=$(ask "Management subnet" 10.73.10.0/24)
  SDN_GATEWAY=$(ask "Gateway (this host on that subnet)" 10.73.10.1)
  CT_IP=$(ask "Management LXC IP/CIDR" 10.73.10.10/24)
  CT_STORAGE=$(ask "Storage for the LXC disk" local-lvm)
  TMPL_STORAGE=$(ask "Storage for templates" local)
  POOL_PREFIX=$(ask "Pool prefix" lab)
  SSH_PUBKEY_FILE=$(ask "SSH public keys to put in the LXC" /root/.ssh/authorized_keys)
  REPO_URL=$(ask "Git repository to clone on the LXC (empty = none)" "")
  umask 077
  {
    echo "# Written by install.sh on $(date -u +%Y-%m-%dT%H:%MZ)."
    echo "# All keys and defaults: ${LIB_DIR}/bootstrap/bootstrap.env.example"
    for k in CTID CT_HOSTNAME SDN_ZONE SDN_VNET SDN_SUBNET SDN_GATEWAY CT_IP \
             CT_STORAGE TMPL_STORAGE POOL_PREFIX SSH_PUBKEY_FILE REPO_URL; do
      echo "${k}=${!k}"
    done
  } > "$CONFIG"
  ok "wrote ${CONFIG}"
fi

# =============================================================
step "Running dsoadm init"
# =============================================================
if [[ "$PIB_NO_INIT" == "1" ]]; then
  skip "PIB_NO_INIT=1. Run it yourself: dsoadm init"
  exit 0
fi
cd /
"$BIN_LINK" init || die "dsoadm init failed. Fix the error above and run: dsoadm init"

echo -e "\n\e[1;32mDone.\e[0m Next time, use: dsoadm help"
