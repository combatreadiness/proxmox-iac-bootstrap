**English** | [한국어](README.ko.md)

# proxmox-iac-bootstrap

A landing zone for IaC on Proxmox VE: an isolated management network, a least-privilege API token, and a management node where OpenTofu is already wired to the API, with Ansible and an SSH key ready for the hosts you create. One command.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
```

Run it as root in the Proxmox host shell. Name the environment (default `lab`), pick Default or Advanced settings, confirm. Running it again is safe, and running it with another name builds a second environment next to the first.

Rather write the settings in a file first and review them? See [Install from a settings file](#install-from-a-settings-file).

## What you get

One environment called `test`, for example:

```
Proxmox VE host
├── API user iac-test@pve + token           limited to the pools, storage and SDN zone below
├── SDN zone "test"
│   └── vnet "testmg" (test-mgmt)           10.73.10.0/24, host is the gateway, SNAT to the internet
├── Pools  test-mgmt                        the management LXC (OpenTofu has no access here)
│          test-workloads                   empty, for OpenTofu to fill (OP_POOLS)
└── LXC 200 "test-mgmt" 10.73.10.10         Debian 12, unprivileged
    ├── OpenTofu (API endpoint and token loaded in every shell), Ansible, git, jq
    ├── /root/.config/test/credentials.env   API endpoint + token, mode 600
    ├── /root/.config/test/host.yml          node name, storage, images (from `dsoadm facts`)
    └── /root/.ssh/id_ed25519                key for Ansible
```

Nothing is installed on the host itself except `dsoadm`. All host work uses the tools Proxmox already ships (`pvesh`, `pveum`, `pct`, `pveam`).

The management LXC is not meant to be managed by OpenTofu. It sits in its own pool that the API token cannot touch, so `tofu destroy` cannot take out the machine running it.

## Environments

Every resource belongs to one named environment: 1 to 6 lowercase letters or digits, starting with a letter. Names are derived from it, so two environments never share a user, a token, a role, a pool or a network.

| Resource | Name for environment `test` |
|---|---|
| Settings / state | `/etc/proxmox-iac-bootstrap/envs/test.env`, `test.state` |
| API user and token | `iac-test@pve!provider` |
| Roles | `IaC-test`, `IaC-test-SDN`, `IaC-test-Clone` (with a VM template) |
| Pools | `test-mgmt`, `test-workloads`, `test-templates` (with a VM template) |
| SDN | zone `test`, vnet `testmg`, shown in the UI as `test-mgmt` |
| Management LXC | `test-mgmt`, tags `mgmt;bootstrap;env-test` |
| Inside the LXC | `/root/.config/test/` |

A new environment gets the first free CTID from 200 and the first free `10.N.10.0/24` subnet from `10.73.10.0/24`. `init` stops if a zone, vnet, CTID, user or pool is already recorded by another environment.

The state file lists what `init` and `template` actually created. Reset removes only what is listed there, so it never touches another environment, or something that existed before (an SDN zone you pointed it at, say).

```bash
dsoadm list                 # every environment and its management node
dsoadm config --env test    # the settings test will use: file plus defaults
```

## Requirements

- Proxmox VE 8.x, single node. Tested on 8.4.
- Root shell on the host.
- Internet access from the host (GitHub, Debian mirrors, OpenTofu apt repository).
- Per environment: one CTID, one /24 subnet, about 10 GB on the LXC storage.

## What the installer does

1. Checks it is on a Proxmox VE host, as root, with the commands it needs.
2. Downloads the latest release archive and `SHA256SUMS` into a temp folder, verifies the checksum and that every file is there.
3. Installs to `/usr/local/lib/proxmox-iac-bootstrap` and links `/usr/local/sbin/dsoadm`.
4. Asks for the environment name, then **Default** (free ID and subnet picked for you) or **Advanced** (one question per setting; the gateway and LXC address follow the subnet), then shows a summary to confirm. The answers go to `/etc/proxmox-iac-bootstrap/envs/<name>.env`. For an existing environment it shows the file and asks whether to keep it.
5. Runs `dsoadm init --env <name>`:
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

Set them in front of the command, e.g. `PIB_ENV=test PIB_YES=1 bash -c "$(curl ...)"`.

| Variable | Default | Meaning |
|---|---|---|
| `PIB_ENV` | `lab` | Environment to create or update |
| `PIB_REF` | `latest` | `latest`, a tag like `v0.2.0`, or `main` (no checksum, for testing) |
| `PIB_YES` | `0` | `1` = take defaults / existing settings without asking |
| `PIB_NO_INIT` | `0` | `1` = install `dsoadm` and write the settings only |
| `PIB_REPO` | this repo | Install from a fork |
| `PIB_SRC` | empty | Install from a local folder instead of GitHub (development) |

A setting given the same way (`CTID=300`, `SDN_SUBNET=10.80.10.0/24`) is written into the settings file, so the file always matches what was built.

To install one exact version, take `install.sh` from that version's tag:

```bash
PIB_REF=v0.2.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/v0.2.0/install.sh)"
```

## Settings

`/etc/proxmox-iac-bootstrap/envs/<name>.env` holds plain `KEY=VALUE` lines. It is parsed, never executed. Every key and its default is listed in [`bootstrap/bootstrap.env.example`](bootstrap/bootstrap.env.example).

The ones you are most likely to change:

| Key | Default | |
|---|---|---|
| `SDN_SUBNET` | first free `10.N.10.0/24` | Management network. `SDN_GATEWAY` (host .1) and `CT_IP` (host .10) follow it |
| `SDN_ZONE`, `SDN_VNET`, `SDN_VNET_ALIAS` | `<env>`, `<env>mg`, `<env>-mgmt` | VNet ID: 8 characters max, letters and digits |
| `CTID`, `CT_HOSTNAME` | first free from 200, `<env>-mgmt` | The management LXC |
| `CT_STORAGE`, `TMPL_STORAGE` | `local-lvm`, `local` | |
| `OP_POOLS` | `workloads` | Pools OpenTofu may fill, space-separated (`tools k8s`); the token only gets those |
| `SSH_PUBKEY_FILE` | `/root/.ssh/authorized_keys` | Keys copied into the LXC |
| `REPO_URL`, `REPO_LINK` | empty | Clone your IaC repository on the LXC, and put one script from it on PATH |
| `PVE_TLS_INSECURE` | `1` | See [Security](#security) |

Change the file, then run `dsoadm init --env <name>` again.

## Install from a settings file

If you'd rather treat the settings like any other IaC file: install first, edit the file, then run.

```bash
# 1. Get the installer, install dsoadm and write the settings for "test". Asks nothing.
curl -fsSLO https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh
PIB_ENV=test PIB_YES=1 PIB_NO_INIT=1 bash install.sh

# 2. Review and edit
vi /etc/proxmox-iac-bootstrap/envs/test.env
dsoadm config --env test

# 3. Build it
dsoadm init --env test
```

Step 1 writes only the common keys. Every other key, with its default and a short note, is in `/usr/local/lib/proxmox-iac-bootstrap/bootstrap/bootstrap.env.example`; copy the lines you need into your file.

Already keep the file in Git? Put it in place first, and the installer uses it as it is:

```bash
install -d -m 700 /etc/proxmox-iac-bootstrap/envs
install -m 600 test.env /etc/proxmox-iac-bootstrap/envs/test.env
PIB_ENV=test PIB_YES=1 bash install.sh
```

## After install

```bash
pct enter 200            # on the host (the CTID of your environment)
tofu version
ansible --version
```

The credentials file is loaded in every new shell. From your PC, the installer prints an `~/.ssh/config` snippet that jumps through the host.

Point your OpenTofu code at the bpg/proxmox provider. It reads `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE` from the environment, so the provider block can stay empty.

Ansible is installed with an SSH key, nothing more. The inventory belongs to whatever you build with OpenTofu.

## dsoadm

Runs on the Proxmox host, as root. Every command takes `--env NAME` (default `lab`).

| Command | What it does |
|---|---|
| `dsoadm init [--rotate-token] [--acl-root]` | Everything above. Safe to re-run. |
| `dsoadm template` | Builds this environment's Debian cloud-init VM template for OpenTofu to clone (optional) |
| `dsoadm facts` | Writes host facts (node, storage, images) to the LXC |
| `dsoadm reset [--dry-run] [--sdn] [--purge] [-y]` | Removes what this environment created |
| `dsoadm list` | Every environment and its management node |
| `dsoadm config` | The settings this environment will use |
| `dsoadm uninstall [--dry-run] [--keep-config] [--all] [-y]` | `reset --purge --sdn` and forget the environment; the tool goes with the last one |
| `dsoadm version` | Installed version |

To update `dsoadm`, run the install command again. Your settings are kept.

## Re-running, recovery, reset

`dsoadm init` checks before it creates:

- SDN zone / vnet / subnet that already exist are kept. If their type, zone, gateway or SNAT differ from your settings you get a warning; nothing is changed.
- A pool that exists without this environment's `managed-by:<env>` marker stops the run. Pick another `POOL_PREFIX`, or set `ALLOW_EXISTING_POOL=1` if you mean it.
- A CTID used by a container with a different hostname stops the run.
- Token handling: the token value is only shown once, so it is kept only while the LXC still has the credentials file. If the LXC is gone, a new token is issued. If the LXC exists but the file is missing, the run stops and tells you to use `--rotate-token`.

Rebuild only the management LXC: `pct stop <ctid> && pct destroy <ctid>`, then `dsoadm init --env <name>`.

`dsoadm reset --env <name>` shows what it will remove and asks you to type the environment name. Use `--dry-run` to only look. The SDN network stays unless you add `--sdn`.

If the environment's pools still have guests that OpenTofu put there, reset stops. Two ways out:

- Destroy them with your own tooling first (`tofu destroy`), then reset.
- `--purge` empties those pools for you, and with `--sdn` it also removes the other vnets in the environment's zone. The OpenTofu state on the management node goes away with it.

Set `TEARDOWN_CMD` in the settings to let your own tool go first. `--purge` runs it inside the management LXC, with that tool's own confirmation, and stops if it fails or you cancel. Anything still left afterwards is destroyed directly.

```
TEARDOWN_CMD=dsoctl down --all
```

To take an environment off the host completely:

```bash
dsoadm uninstall --env test --dry-run   # look first
dsoadm uninstall --env test
```

That is `reset --purge --sdn`, then the settings file goes too (keep it with `--keep-config`). Other environments stay. When the last one is gone, uninstall also removes the downloaded Debian LXC template and cloud image, `/usr/local/lib/proxmox-iac-bootstrap`, `/usr/local/sbin/dsoadm` and `/etc/proxmox-iac-bootstrap`. `--all` does every environment in one go. Back up anything on a management node you want to keep first.

Upgrading from v0.1: the old `/etc/proxmox-iac-bootstrap/bootstrap.env` is moved to `envs/lab.env`, but v0.1 used other names (`terraform@pve`, `TerraformRole`, `lab-*` pools without a state file). Reset the v0.1 setup with v0.1 first, then build with v0.2.

## Security

- **API scope.** By default the token can work inside the environment's `OP_POOLS` pools, the two storages, and its SDN zone, plus read-only on the node. It cannot see the management pool, or any other environment. `--acl-root` gives it the whole datacenter; do not use that outside debugging.
- **Secrets.** The token is never printed. It goes from a mode-600 temp file on the host (removed on exit) to `/root/.config/<env>/credentials.env` (mode 600) in the LXC. The API check in the LXC passes the header from a file, so the token does not show up in `ps`.
- **SSH keys.** Keys from `SSH_PUBKEY_FILE` are merged into the LXC's `authorized_keys`. Existing keys are kept. On Proxmox the default file also contains the cluster's own keys.
- **TLS.** `PVE_TLS_INSECURE=1` is the default because Proxmox ships a self-signed certificate and the LXC talks to the host on its SDN address, which is not in that certificate. Set it to `0` once the LXC trusts a certificate that matches the endpoint.
- **Downloads.** Release archives are checked against `SHA256SUMS`. Both come from the same GitHub release, so this catches broken downloads, not a compromised repository. Each release archive also carries a build provenance attestation; check it with `gh attestation verify <archive> -R combatreadiness/proxmox-iac-bootstrap`. The LXC template comes through `pveam`, OpenTofu through its signed apt repository.

## Known limitations

- Single-node clusters only.
- `PVE_TLS_INSECURE=1` by default (see above).
- The OpenTofu role still includes broad privileges such as `Sys.Modify`, `User.Modify` and `Datastore.Allocate`. Trimming them needs another round of testing with real OpenTofu code.
- `pvesh set /cluster/sdn` applies all pending SDN changes on the cluster, not only the ones made here.
- OpenTofu is installed at whatever version the apt repository has at the time.
- Storage is typed, not picked from a list.

## License

Apache-2.0. See [LICENSE](LICENSE).
