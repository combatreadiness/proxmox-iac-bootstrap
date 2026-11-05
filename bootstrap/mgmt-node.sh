#!/usr/bin/env bash
# =============================================================
# mgmt-node.sh — Turn a Debian/Ubuntu machine into a management node
#   1) Install base tools (git, curl, jq, ansible, ...)
#   2) Install OpenTofu
#   3) Create an SSH key for Ansible
#   4) Load the credentials file in new shells (if present)
#   5) Verify provider credentials (currently: Proxmox, when configured)
#   6) Optional: clone a repository              -> REPO_URL
#   7) Optional: put a file from it on PATH       -> REPO_LINK
#
# Works on : Debian / Ubuntu (VM, LXC, WSL, bare metal, cloud)
# Run as   : root, or a user with sudo
# Usage    : ./mgmt-node.sh
#            REPO_URL=https://github.com/you/repo.git REPO_LINK=mycli ./mgmt-node.sh
#            MGMT_CONFIG=./mgmt.env ./mgmt-node.sh
# Re-run   : Safe
# =============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none   # Never stop on a changelog pager
export LC_ALL=C.UTF-8 LANG=C.UTF-8     # Always available; avoids locale warnings

log()  { echo -e "\e[1;34m[mgmt]\e[0m $*"; }
warn() { echo -e "\e[1;33m[mgmt]\e[0m $*"; }
die()  { echo -e "\e[1;31m[mgmt]\e[0m $*" >&2; exit 1; }

# ---------- Optional config file (KEY=VALUE lines only, never executed) ----------
if [[ -n "${MGMT_CONFIG:-}" && -f "$MGMT_CONFIG" ]]; then
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key//[[:space:]]/}"
    if [[ -z "$key" || "$key" == \#* ]]; then continue; fi
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then continue; fi
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "${!key+x}" ]]; then printf -v "$key" '%s' "$value"; fi
  done < "$MGMT_CONFIG"
fi

# ---------- Settings ----------
PROJECT_ID="${PROJECT_ID:-lab}"
INSTALL_TOFU="${INSTALL_TOFU:-1}"
INSTALL_ANSIBLE="${INSTALL_ANSIBLE:-1}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
CRED_FILE="${CRED_FILE:-$HOME/.config/${PROJECT_ID}/credentials.env}"
REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-$HOME/${PROJECT_ID}}"
REPO_LINK="${REPO_LINK:-}"             # File in the repository to link into /usr/local/bin

# Use sudo only when not running as root
SUDO=()
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || die "Run as root or install sudo."
  SUDO=(sudo)
fi

# ---------- 0. OS check ----------
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
  die "Unsupported OS '${ID:-unknown}'. Debian/Ubuntu only for now."
fi
log "OS: ${PRETTY_NAME:-$ID}"

# ---------- 1. Base tools ----------
PKGS=(git curl ca-certificates gnupg unzip jq python3 openssh-client)
if [[ "$INSTALL_ANSIBLE" == "1" ]]; then PKGS+=(ansible); fi
log "Installing packages: ${PKGS[*]}"
"${SUDO[@]}" apt-get update -qq
"${SUDO[@]}" apt-get install -y -qq "${PKGS[@]}" >/dev/null

# ---------- 1b. Locale ----------
# SSH clients forward LANG (e.g. en_US.UTF-8); Ansible fails if it is not installed.
LOCALE_WANT="${LOCALE_WANT:-en_US.UTF-8}"
if ! locale -a 2>/dev/null | grep -qix "${LOCALE_WANT/UTF-8/utf8}"; then
  log "Generating locale ${LOCALE_WANT}"
  "${SUDO[@]}" apt-get install -y -qq locales >/dev/null
  "${SUDO[@]}" sed -i "s/^# *\(${LOCALE_WANT} UTF-8\)/\1/" /etc/locale.gen
  "${SUDO[@]}" locale-gen >/dev/null
  "${SUDO[@]}" update-locale LANG="$LOCALE_WANT"
fi

# ---------- 2. OpenTofu ----------
# Installed from the OpenTofu apt repository; apt checks the package signatures.
if [[ "$INSTALL_TOFU" != "1" ]]; then
  log "Skipping OpenTofu (INSTALL_TOFU=0)"
elif command -v tofu >/dev/null; then
  log "OpenTofu already installed -> skipping"
else
  log "Installing OpenTofu"
  INSTALLER="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o "$INSTALLER"
  chmod +x "$INSTALLER"
  "${SUDO[@]}" "$INSTALLER" --install-method deb >/dev/null
  rm -f "$INSTALLER"
fi

# ---------- 3. SSH key ----------
if [[ -f "$SSH_KEY_PATH" ]]; then
  log "SSH key already exists at ${SSH_KEY_PATH} -> skipping"
else
  log "Creating SSH key at ${SSH_KEY_PATH}"
  install -d -m 700 "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -q -t ed25519 -N "" -C "${PROJECT_ID}-mgmt@$(hostname)" -f "$SSH_KEY_PATH"
fi

# ---------- 3b. PATH for shells that skip the login profile ----------
# `pct enter` opens a shell without /usr/local/bin on PATH.
PATH_LINE='case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac'
if ! grep -qF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  log "Adding /usr/local/bin to PATH in ~/.bashrc (for pct enter shells)"
  echo "$PATH_LINE" >> "$HOME/.bashrc"
fi

# ---------- 4. Credentials ----------
if [[ -f "$CRED_FILE" ]]; then
  perms=$(stat -c '%a' "$CRED_FILE")
  if [[ "$perms" != "600" && "$perms" != "400" ]]; then
    warn "${CRED_FILE} has mode ${perms}; setting it to 600"
    chmod 600 "$CRED_FILE"
  fi
  if ! grep -qF "$CRED_FILE" "$HOME/.bashrc" 2>/dev/null; then
    log "Loading ${CRED_FILE} in new shells (~/.bashrc)"
    echo "[ -f \"$CRED_FILE\" ] && source \"$CRED_FILE\"" >> "$HOME/.bashrc"
  fi
  # shellcheck source=/dev/null
  source "$CRED_FILE"
else
  log "No credentials file at ${CRED_FILE} (fine if you add one later)"
fi

# ---------- 5. Provider checks (only when configured) ----------
check_proxmox() {
  local tmp hdr code
  local -a tls=()
  tmp="$(mktemp)"
  hdr="$(mktemp)"            # mktemp files are 0600
  # Header comes from a file so the token never shows up in `ps`
  printf 'Authorization: PVEAPIToken=%s\n' "${PROXMOX_VE_API_TOKEN:-}" > "$hdr"
  if [[ "${PROXMOX_VE_INSECURE:-false}" == "true" ]]; then
    tls=(-k)
    warn "TLS certificate check is off (PROXMOX_VE_INSECURE=true)"
  fi
  log "Verifying Proxmox API at ${PROXMOX_VE_ENDPOINT}"
  code=$(curl -s "${tls[@]}" -o "$tmp" -w '%{http_code}' -H "@${hdr}" \
    "${PROXMOX_VE_ENDPOINT%/}/api2/json/version" || true)
  rm -f "$hdr"
  case "$code" in
    200) log "Proxmox API OK: version $(jq -r '.data.version' "$tmp")" ;;
    401) rm -f "$tmp"; die "Proxmox API token rejected (401). Reissue the token." ;;
    000) rm -f "$tmp"; die "Cannot reach ${PROXMOX_VE_ENDPOINT} (network, firewall, or TLS certificate)." ;;
    *)   rm -f "$tmp"; die "Unexpected response from Proxmox API: HTTP ${code}" ;;
  esac
  rm -f "$tmp"
}

if [[ -n "${PROXMOX_VE_ENDPOINT:-}" ]]; then check_proxmox; fi
# Other providers can be added here with the same pattern.

# ---------- 6. Optional: clone repository ----------
if [[ -n "$REPO_URL" ]]; then
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Repository exists at ${REPO_DIR} -> pulling"
    git -C "$REPO_DIR" pull --ff-only
  else
    log "Cloning ${REPO_URL} into ${REPO_DIR}"
    git clone "$REPO_URL" "$REPO_DIR"
  fi
fi

# ---------- 7. Optional: link a file from the repository onto PATH ----------
# Works however the repository got here (clone above, copy, archive).
if [[ -n "$REPO_LINK" ]]; then
  [[ "$REPO_LINK" != */* && "$REPO_LINK" != .* ]] || die "REPO_LINK must be a plain file name, got '${REPO_LINK}'"
  if [[ -x "$REPO_DIR/$REPO_LINK" ]]; then
    "${SUDO[@]}" ln -sf "$REPO_DIR/$REPO_LINK" "/usr/local/bin/$REPO_LINK"
    log "Linked: /usr/local/bin/${REPO_LINK} -> ${REPO_DIR}/${REPO_LINK}"
  else
    log "No executable ${REPO_DIR}/${REPO_LINK} yet. After getting the repository, run this script again."
  fi
fi

log "Done. Installed:"
if command -v tofu    >/dev/null; then echo "  $(tofu version | head -n1)"; fi
if command -v ansible >/dev/null; then echo "  $(ansible --version | head -n1)"; fi
echo "  $(git --version)"
