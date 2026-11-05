# proxmox-iac-bootstrap

From a fresh Proxmox VE host to a management container that can run OpenTofu and Ansible against it, with one command.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
```

Run it as root in the Proxmox host shell. Pick Default or Advanced settings, confirm, and it sets everything up. Running it again is safe.

## What you get

```
Proxmox VE host
├── API user terraform@pve + token        limited to the pools, storage and SDN zone below
├── SDN zone "lab"
│   └── vnet "lmgmt" 10.73.10.0/24        host is the gateway (10.73.10.1), SNAT to the internet
├── Pools  lab-mgmt                       the management LXC (OpenTofu has no access here)
│          lab-tools, lab-k8s, lab-targets  empty, for OpenTofu to fill
└── LXC 200 "iac-mgmt" 10.73.10.10        Debian 12, unprivileged
    ├── OpenTofu, Ansible, git, jq
    ├── /root/.config/lab/credentials.env  API endpoint + token, mode 600
    ├── /root/.config/lab/host.yml         node name, storage, images (from `dsoadm facts`)
    └── /root/.ssh/id_ed25519              key for Ansible
```

Nothing is installed on the host itself except `dsoadm`. All host work uses the tools Proxmox already ships (`pvesh`, `pveum`, `pct`, `pveam`).

The management LXC is not meant to be managed by OpenTofu. It sits in its own pool that the API token cannot touch, so `tofu destroy` cannot take out the machine running it.

## Requirements

- Proxmox VE 8.x, single node. Tested on 8.4.
- Root shell on the host.
- Internet access from the host (GitHub, Debian mirrors, OpenTofu apt repository).
- Free: one CTID (default 200), the subnet 10.73.10.0/24 (or pick another), about 10 GB on the LXC storage.

## What the installer does

1. Checks it is on a Proxmox VE host, as root, with the commands it needs.
2. Asks for settings: **Default** or **Advanced** (one question per setting), then shows a summary to confirm. The answers go to `/etc/proxmox-iac-bootstrap/bootstrap.env`. If that file exists, it shows it and asks whether to keep it.
3. Downloads the latest release archive and `SHA256SUMS` into a temp folder, verifies the checksum and that every file is there.
4. Installs to `/usr/local/lib/proxmox-iac-bootstrap` and links `/usr/local/sbin/dsoadm`.
5. Runs `dsoadm init`:
   - API roles, user and token
   - SDN zone, vnet, subnet (created only if missing; existing ones are checked against your settings and left alone)
   - Pools and ACLs
   - Debian LXC template, then the LXC
   - Network check from inside the LXC (gateway, then internet, then DNS, so you see where it breaks)
   - Credentials and SSH keys pushed into the LXC
   - `mgmt-node.sh` inside the LXC: packages, OpenTofu, SSH key, API check
   - Host facts written to the LXC

The temp folder is removed when the installer exits, whether it worked or not.

### Installer options

Set them in front of the command, e.g. `PIB_YES=1 bash -c "$(curl ...)"`.

| Variable | Default | Meaning |
|---|---|---|
| `PIB_REF` | `latest` | `latest`, a tag like `v0.1.0`, or `main` (no checksum, for testing) |
| `PIB_YES` | `0` | `1` = take defaults / existing config without asking |
| `PIB_NO_INIT` | `0` | `1` = install `dsoadm` only |
| `PIB_REPO` | this repo | Install from a fork |

## Settings

`/etc/proxmox-iac-bootstrap/bootstrap.env` holds plain `KEY=VALUE` lines. It is parsed, never executed. Every key and its default is listed in [`bootstrap/bootstrap.env.example`](bootstrap/bootstrap.env.example).

The ones you are most likely to change:

| Key | Default | |
|---|---|---|
| `CTID`, `CT_HOSTNAME`, `CT_IP` | `200`, `iac-mgmt`, `10.73.10.10/24` | The management LXC |
| `SDN_ZONE`, `SDN_VNET`, `SDN_SUBNET`, `SDN_GATEWAY` | `lab`, `lmgmt`, `10.73.10.0/24`, `10.73.10.1` | Management network |
| `CT_STORAGE`, `TMPL_STORAGE` | `local-lvm`, `local` | |
| `POOL_PREFIX`, `OP_POOLS` | `lab`, `tools k8s targets` | Pool names; the API token only gets the `OP_POOLS` ones |
| `SSH_PUBKEY_FILE` | `/root/.ssh/authorized_keys` | Keys copied into the LXC |
| `REPO_URL`, `REPO_LINK` | empty | Clone your IaC repository on the LXC, and put one script from it on PATH |
| `PVE_TLS_INSECURE` | `1` | See [Security](#security) |

Change the file, then run `dsoadm init` again.

## After install

```bash
pct enter 200            # on the host
tofu version
ansible --version
source ~/.config/lab/credentials.env   # already loaded in new shells
```

From your PC, the installer prints an `~/.ssh/config` snippet that jumps through the host.

Point your OpenTofu code at the bpg/proxmox provider. It reads `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE` from the environment, so the provider block can stay empty.

## dsoadm

Runs on the Proxmox host, as root.

| Command | What it does |
|---|---|
| `dsoadm init [--rotate-token] [--acl-root]` | Everything above. Safe to re-run. |
| `dsoadm template` | Builds a Debian cloud-init VM template for OpenTofu to clone |
| `dsoadm facts` | Writes host facts (node, storage, images) to the LXC |
| `dsoadm reset [--dry-run] [--sdn] [--purge] [-y]` | Removes what `init` and `template` created |
| `dsoadm version` | Installed version and which config file is used |

To update `dsoadm`, run the install command again. Your config is kept.

## Re-running, recovery, reset

`dsoadm init` checks before it creates:

- SDN zone / vnet / subnet that already exist are kept. If their type, zone, gateway or SNAT differ from your settings you get a warning; nothing is changed.
- A pool that exists but was not created by this project (no `managed-by:<PROJECT_ID>` in its comment) stops the run. Pick another `POOL_PREFIX`, or set `ALLOW_EXISTING_POOL=1` if you mean it.
- A CTID used by a container with a different hostname stops the run.
- Token handling: the token value is only shown once, so it is kept only while the LXC still has the credentials file. If the LXC is gone, a new token is issued. If the LXC exists but the file is missing, the run stops and tells you to use `--rotate-token`.

Rebuild only the management LXC: `pct stop 200 && pct destroy 200`, then `dsoadm init`.

`dsoadm reset` shows what it will remove and asks first. Use `--dry-run` to only look. It only touches what this project created. The SDN network stays unless you add `--sdn`.

If the OpenTofu pools still have guests in them, reset stops. You have two ways out:

- Destroy them with your own tooling first (`tofu destroy`), then reset.
- `dsoadm reset --purge` empties those pools for you. With `--sdn` it also removes the other vnets in the zone. The pools and the zone were created here, so reset treats what is inside them as its to clean up. The OpenTofu state on the management node goes away with it.

Set `TEARDOWN_CMD` in the config to let your own tool go first. `--purge` runs it inside the management LXC, with that tool's own confirmation, and stops if it fails or you cancel. Anything still left afterwards is destroyed directly.

```
TEARDOWN_CMD=dsoctl down --all
```

## Security

- **API scope.** By default the token can work inside the `OP_POOLS` pools, the two storages, and the SDN zone, plus read-only on the node. It cannot see the management pool. `--acl-root` gives it the whole datacenter; do not use that outside debugging.
- **Secrets.** The token is never printed. It goes from a mode-600 temp file on the host (removed on exit) to `/root/.config/<PROJECT_ID>/credentials.env` (mode 600) in the LXC. The API check in the LXC passes the header from a file, so the token does not show up in `ps`.
- **SSH keys.** Keys from `SSH_PUBKEY_FILE` are merged into the LXC's `authorized_keys`. Existing keys are kept. Note that on Proxmox the default file also contains the cluster's own keys.
- **TLS.** `PVE_TLS_INSECURE=1` is the default because Proxmox ships a self-signed certificate and the LXC talks to the host on its SDN address, which is not in that certificate. Set it to `0` once the LXC trusts a certificate that matches the endpoint.
- **Downloads.** Release archives are checked against `SHA256SUMS`. Both come from the same GitHub release, so this catches broken downloads, not a compromised repository. The LXC template comes through `pveam`, OpenTofu through its signed apt repository.

## Known limitations

- Single-node clusters only.
- `PVE_TLS_INSECURE=1` by default (see above).
- The OpenTofu role still includes broad privileges such as `Sys.Modify`, `User.Modify` and `Datastore.Allocate`. Trimming them needs another round of testing with real OpenTofu code.
- `pvesh set /cluster/sdn` applies all pending SDN changes on the cluster, not only the ones made here.
- OpenTofu is installed at whatever version the apt repository has at the time.
- The installer asks only for the main settings (Default or Advanced); the rest go in the config file.
- Install from a release on a fresh host has not been run end to end yet after splitting this out of a larger lab project. The scripts themselves were rebuilt from scratch twice in that project.

## License

Apache-2.0. See [LICENSE](LICENSE).
