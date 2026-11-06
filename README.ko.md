[English](README.md) | **한국어**

# proxmox-iac-bootstrap

Proxmox VE에 IaC를 올리기 전에 깔아 둘 바닥, 즉 랜딩 존(Landing Zone)을 명령 한 줄로 만듭니다. 분리된 관리망, 꼭 필요한 권한만 가진 API 토큰, 그리고 OpenTofu가 이미 API에 연결된 관리 노드까지 준비합니다. Ansible은 설치와 SSH 키까지만 해 둡니다.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh)"
```

Proxmox 호스트 셸에서 root로 실행합니다. 환경 이름(기본값 `lab`)을 정하고, Default나 Advanced 설정을 고른 뒤 확인하면 끝입니다. 다시 실행해도 안전하고, 다른 이름으로 실행하면 첫 번째 환경 옆에 두 번째 환경이 생깁니다.

설정 파일을 먼저 쓰고 검토한 다음 돌리고 싶다면 [설정 파일로 설치하기](#설정-파일로-설치하기)를 보세요.

## 무엇이 만들어지나

`test`라는 환경 하나를 예로 들면 이렇습니다.

```
Proxmox VE 호스트
├── API 사용자 iac-test@pve + 토큰          아래 Pool, 스토리지, SDN Zone 안에서만 동작
├── SDN Zone "test"
│   └── VNet "testmg" (test-mgmt)           10.73.10.0/24, 호스트가 게이트웨이, 인터넷은 SNAT
├── Pool  test-mgmt                         관리 LXC 자리 (OpenTofu는 접근 불가)
│         test-workloads                    비어 있음, OpenTofu가 채울 자리 (OP_POOLS)
└── LXC 200 "test-mgmt" 10.73.10.10         Debian 12, unprivileged
    ├── OpenTofu (API 주소와 토큰이 모든 셸에 로드됨), Ansible, git, jq
    ├── /root/.config/test/credentials.env   API 주소 + 토큰, 권한 600
    ├── /root/.config/test/host.yml          노드 이름, 스토리지, 이미지 (`dsoadm facts`)
    └── /root/.ssh/id_ed25519                Ansible용 SSH 키
```

호스트에는 `dsoadm` 말고는 아무것도 설치하지 않습니다. 호스트 작업은 전부 Proxmox에 원래 있는 도구(`pvesh`, `pveum`, `pct`, `pveam`)로 합니다.

관리 LXC는 OpenTofu로 관리하는 대상이 아닙니다. API 토큰이 손댈 수 없는 별도 Pool에 들어 있어서, `tofu destroy`가 자기를 돌리는 머신을 지울 일이 없습니다.

## 환경

모든 자원은 이름이 붙은 환경 하나에 속합니다. 이름은 소문자로 시작하는 소문자·숫자 1~6자입니다. 다른 이름들이 전부 이 이름에서 만들어지기 때문에, 두 환경이 사용자·토큰·Role·Pool·네트워크를 함께 쓰는 일이 없습니다.

| 자원 | `test` 환경의 이름 |
|---|---|
| 설정 / 상태 | `/etc/proxmox-iac-bootstrap/envs/test.env`, `test.state` |
| API 사용자와 토큰 | `iac-test@pve!provider` |
| Role | `IaC-test`, `IaC-test-SDN`, `IaC-test-Clone` (VM 템플릿을 만들 때) |
| Pool | `test-mgmt`, `test-workloads`, `test-templates` (VM 템플릿을 만들 때) |
| SDN | Zone `test`, VNet `testmg` (Proxmox 화면에는 `test-mgmt`로 표시) |
| 관리 LXC | `test-mgmt`, 태그 `mgmt;bootstrap;env-test` |
| LXC 안 경로 | `/root/.config/test/` |

새 환경은 200부터 비어 있는 첫 CTID와, `10.73.10.0/24`부터 비어 있는 첫 `10.N.10.0/24` 대역을 받습니다. 다른 환경이 이미 기록해 둔 Zone, VNet, CTID, 사용자, Pool을 쓰려고 하면 `init`이 멈춥니다.

상태 파일에는 `init`과 `template`이 실제로 새로 만든 것만 기록됩니다. reset은 여기 적힌 것만 지웁니다. 그래서 다른 환경이나, 원래부터 있던 것(직접 만들어 둔 SDN Zone을 지정한 경우 등)은 건드리지 않습니다.

```bash
dsoadm list                 # 모든 환경과 관리 노드 상태
dsoadm config --env test    # test가 실제로 쓸 설정 (파일 + 기본값)
```

## 요구사항

- Proxmox VE 8.x, 단일 노드. 8.4에서 확인했습니다.
- 호스트의 root 셸
- 호스트에서 인터넷 접속 (GitHub, Debian 미러, OpenTofu apt 저장소)
- 환경마다 CTID 하나, /24 대역 하나, LXC 스토리지 약 10GB

## 설치기가 하는 일

1. Proxmox VE 호스트인지, root인지, 필요한 명령이 있는지 확인합니다.
2. 최신 Release 압축 파일과 `SHA256SUMS`를 임시 폴더에 받고, 체크섬과 파일 구성을 확인합니다.
3. `/usr/local/lib/proxmox-iac-bootstrap`에 설치하고 `/usr/local/sbin/dsoadm` 링크를 만듭니다.
4. 환경 이름을 묻고, **Default**(빈 ID와 대역을 알아서 고름) 또는 **Advanced**(항목마다 하나씩 묻고, 게이트웨이와 LXC 주소는 서브넷을 따라감)를 고르게 한 뒤, 요약을 보여주고 확인을 받습니다. 답은 `/etc/proxmox-iac-bootstrap/envs/<이름>.env`에 저장합니다. 이미 있는 환경이면 파일 내용을 보여주고 그대로 쓸지 묻습니다.
5. `dsoadm init --env <이름>`을 실행합니다.
   - API Role, 사용자, 토큰
   - SDN Zone, VNet, Subnet (없을 때만 만들고, 있으면 설정과 맞는지만 확인)
   - Pool과 ACL
   - Debian LXC 템플릿, 그리고 LXC
   - LXC 안에서 네트워크 확인 (게이트웨이 → 인터넷 → DNS 순서라 어디서 막혔는지 보입니다)
   - 인증정보와 SSH 키를 LXC에 넣기
   - LXC 안에서 `mgmt-node.sh` 실행: 패키지, OpenTofu, SSH 키, API 확인
   - 호스트 정보를 LXC에 기록

임시 폴더는 설치기가 끝날 때 성공 여부와 상관없이 지웁니다.

### 설치기 옵션

명령 앞에 붙입니다. 예: `PIB_ENV=test PIB_YES=1 bash -c "$(curl ...)"`

| 변수 | 기본값 | 의미 |
|---|---|---|
| `PIB_ENV` | `lab` | 만들거나 고칠 환경 |
| `PIB_REF` | `latest` | `latest`, `v0.2.0` 같은 태그, 또는 `main`(체크섬 없음, 테스트용) |
| `PIB_YES` | `0` | `1` = 묻지 않고 기본값 또는 기존 설정 사용 |
| `PIB_NO_INIT` | `0` | `1` = `dsoadm` 설치와 설정 저장까지만 |
| `PIB_REPO` | 이 저장소 | 포크에서 설치 |
| `PIB_SRC` | 비어 있음 | GitHub 대신 로컬 폴더에서 설치 (개발용) |

같은 방식으로 넘긴 설정 값(`CTID=300`, `SDN_SUBNET=10.80.10.0/24`)은 설정 파일에도 저장됩니다. 그래서 파일과 실제로 만들어진 결과가 항상 같습니다.

특정 버전을 그대로 설치하려면, 그 버전 태그의 `install.sh`를 쓰세요.

```bash
PIB_REF=v0.2.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/v0.2.0/install.sh)"
```

## 설정

`/etc/proxmox-iac-bootstrap/envs/<이름>.env`에는 `KEY=VALUE` 줄만 들어 있습니다. 읽기만 하고 실행하지는 않습니다. 모든 키와 기본값은 [`bootstrap/bootstrap.env.example`](bootstrap/bootstrap.env.example)에 있습니다.

자주 바꾸는 항목은 이렇습니다.

| 키 | 기본값 | |
|---|---|---|
| `SDN_SUBNET` | 비어 있는 첫 `10.N.10.0/24` | 관리망. `SDN_GATEWAY`(.1)와 `CT_IP`(.10)가 따라감 |
| `SDN_ZONE`, `SDN_VNET`, `SDN_VNET_ALIAS` | `<환경>`, `<환경>mg`, `<환경>-mgmt` | VNet ID는 8자 이내, 영문·숫자 |
| `CTID`, `CT_HOSTNAME` | 200부터 비어 있는 첫 번호, `<환경>-mgmt` | 관리 LXC |
| `CT_STORAGE`, `TMPL_STORAGE` | `local-lvm`, `local` | |
| `OP_POOLS` | `workloads` | OpenTofu가 쓸 Pool, 띄어쓰기로 여러 개(`tools k8s`). 토큰은 이 Pool에만 권한을 받음 |
| `SSH_PUBKEY_FILE` | `/root/.ssh/authorized_keys` | LXC에 넣을 공개키 |
| `REPO_URL`, `REPO_LINK` | 비어 있음 | 관리 노드에 IaC 저장소를 clone하고, 그 안의 스크립트 하나를 PATH에 연결 |
| `PVE_TLS_INSECURE` | `1` | [보안](#보안) 참고 |

파일을 고친 다음 `dsoadm init --env <이름>`을 다시 실행하면 됩니다.

## 설정 파일로 설치하기

설정을 다른 IaC 파일처럼 다루고 싶다면, 먼저 설치하고, 파일을 고치고, 그다음 실행하면 됩니다.

```bash
# 1. 설치기를 받아 dsoadm을 설치하고 "test" 환경 설정 파일을 만듭니다. 아무것도 묻지 않습니다.
curl -fsSLO https://raw.githubusercontent.com/combatreadiness/proxmox-iac-bootstrap/main/install.sh
PIB_ENV=test PIB_YES=1 PIB_NO_INIT=1 bash install.sh

# 2. 검토하고 고칩니다
vi /etc/proxmox-iac-bootstrap/envs/test.env
dsoadm config --env test

# 3. 만듭니다
dsoadm init --env test
```

1단계에서는 자주 쓰는 키만 파일에 들어갑니다. 나머지 키는 기본값과 설명이 `/usr/local/lib/proxmox-iac-bootstrap/bootstrap/bootstrap.env.example`에 있으니, 필요한 줄만 복사해 넣으면 됩니다.

설정 파일을 Git에 두고 쓴다면, 먼저 제자리에 넣어 두세요. 설치기가 그 파일을 그대로 씁니다.

```bash
install -d -m 700 /etc/proxmox-iac-bootstrap/envs
install -m 600 test.env /etc/proxmox-iac-bootstrap/envs/test.env
PIB_ENV=test PIB_YES=1 bash install.sh
```

## 설치 후

```bash
pct enter 200            # 호스트에서 (환경의 CTID)
tofu version
ansible --version
```

인증정보 파일은 새 셸마다 자동으로 로드됩니다. PC에서 접속할 때 쓸 `~/.ssh/config` 예시는 설치가 끝날 때 화면에 나옵니다(호스트를 거쳐 들어가는 ProxyJump 방식).

OpenTofu 코드에서는 bpg/proxmox provider를 쓰면 됩니다. `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_INSECURE`를 환경변수에서 읽기 때문에 provider 블록은 비워 둬도 됩니다.

Ansible은 설치와 SSH 키까지만 합니다. 인벤토리는 OpenTofu로 만드는 대상 쪽에서 정하는 게 맞으니까요.

## dsoadm

Proxmox 호스트에서 root로 실행합니다. 모든 명령에 `--env 이름`을 붙일 수 있습니다(기본값 `lab`).

| 명령 | 하는 일 |
|---|---|
| `dsoadm init [--rotate-token] [--acl-root]` | 위의 전부. 다시 실행해도 안전 |
| `dsoadm template` | 이 환경 전용 Debian cloud-init VM 템플릿 만들기 (선택) |
| `dsoadm facts` | 호스트 정보(노드, 스토리지, 이미지)를 LXC에 기록 |
| `dsoadm reset [--dry-run] [--sdn] [--purge] [-y]` | 이 환경이 만든 것 지우기 |
| `dsoadm list` | 모든 환경과 관리 노드 상태 |
| `dsoadm config` | 이 환경이 실제로 쓸 설정 |
| `dsoadm uninstall [--dry-run] [--keep-config] [--all] [-y]` | `reset --purge --sdn` 후 환경 정보까지 삭제. 도구는 마지막 환경과 함께 삭제 |
| `dsoadm version` | 설치된 버전 |

`dsoadm`을 업데이트하려면 설치 명령을 다시 실행하면 됩니다. 설정은 그대로 남습니다.

## 재실행, 복구, reset

`dsoadm init`은 만들기 전에 확인합니다.

- 이미 있는 SDN Zone / VNet / Subnet은 그대로 둡니다. 타입, Zone, 게이트웨이, SNAT이 설정과 다르면 경고만 하고 바꾸지 않습니다.
- 이 환경의 `managed-by:<환경>` 표식이 없는 Pool이 이미 있으면 멈춥니다. `POOL_PREFIX`를 바꾸거나, 의도한 거라면 `ALLOW_EXISTING_POOL=1`을 설정하세요.
- 다른 호스트 이름의 컨테이너가 같은 CTID를 쓰고 있으면 멈춥니다.
- 토큰: 토큰 값은 발급할 때 한 번만 보입니다. 그래서 LXC 안에 인증정보 파일이 남아 있을 때만 기존 토큰을 유지합니다. LXC가 없으면 새로 발급하고, LXC는 있는데 파일이 없으면 멈추고 `--rotate-token`을 쓰라고 안내합니다.

관리 LXC만 다시 만들려면 `pct stop <ctid> && pct destroy <ctid>` 후 `dsoadm init --env <이름>`을 실행하세요.

`dsoadm reset --env <이름>`은 지울 목록을 먼저 보여주고, 환경 이름을 입력해야 진행합니다. `--dry-run`이면 보기만 합니다. SDN은 `--sdn`을 붙이지 않으면 남깁니다.

환경의 Pool에 OpenTofu가 만든 게스트가 남아 있으면 reset은 멈춥니다. 방법은 두 가지입니다.

- 쓰던 도구로 먼저 지우고(`tofu destroy`) reset합니다.
- `--purge`를 붙이면 그 Pool들을 비워 줍니다. `--sdn`도 같이 주면 환경 Zone 안의 다른 VNet까지 지웁니다. 관리 노드 안의 OpenTofu state도 같이 사라집니다.

설정에 `TEARDOWN_CMD`를 넣으면 쓰던 도구가 먼저 정리하게 할 수 있습니다. `--purge`가 관리 LXC 안에서 그 명령을 실행하고, 그 도구의 확인 절차를 그대로 거칩니다. 실패하거나 취소하면 아무것도 지우지 않고 멈춥니다. 그 뒤에 남은 것만 직접 지웁니다.

```
TEARDOWN_CMD=dsoctl down --all
```

환경 하나를 호스트에서 완전히 걷어내려면:

```bash
dsoadm uninstall --env test --dry-run   # 먼저 확인
dsoadm uninstall --env test
```

`reset --purge --sdn`을 한 다음 설정 파일까지 지웁니다(`--keep-config`로 남길 수 있음). 다른 환경은 그대로입니다. 마지막 환경까지 지우면, 받아 둔 Debian LXC 템플릿과 클라우드 이미지, `/usr/local/lib/proxmox-iac-bootstrap`, `/usr/local/sbin/dsoadm`, `/etc/proxmox-iac-bootstrap`도 함께 지웁니다. `--all`은 모든 환경을 한 번에 처리합니다. 관리 노드에 남겨야 할 게 있으면 먼저 백업하세요.

v0.1에서 올라오는 경우: 예전 `/etc/proxmox-iac-bootstrap/bootstrap.env`는 `envs/lab.env`로 옮겨집니다. 하지만 v0.1은 다른 이름(`terraform@pve`, `TerraformRole`, 상태 파일 없는 `lab-*` Pool)을 썼습니다. v0.1로 만든 환경은 v0.1로 먼저 reset한 다음 v0.2로 새로 만드세요.

## 보안

- **API 권한 범위**: 기본적으로 토큰은 환경의 `OP_POOLS` Pool, 스토리지 두 개, 환경의 SDN Zone 안에서만 동작하고, 노드 정보는 읽기만 합니다. 관리 Pool과 다른 환경은 보지 못합니다. `--acl-root`는 데이터센터 전체 권한이니 디버깅 말고는 쓰지 마세요.
- **비밀값**: 토큰은 화면에 출력하지 않습니다. 호스트의 권한 600 임시 파일(끝나면 삭제)을 거쳐 LXC 안 `/root/.config/<환경>/credentials.env`(권한 600)로만 들어갑니다. LXC 안에서 API를 확인할 때도 헤더를 파일로 넘겨서 `ps`에 토큰이 보이지 않습니다.
- **SSH 키**: `SSH_PUBKEY_FILE`의 키를 LXC의 `authorized_keys`에 합칩니다. 기존 키는 지우지 않습니다. Proxmox의 기본 파일에는 클러스터 노드 키도 들어 있다는 점은 알아 두세요.
- **TLS**: 기본값이 `PVE_TLS_INSECURE=1`입니다. Proxmox 기본 인증서는 자체 서명이고, LXC는 호스트의 SDN 주소로 접속하는데 그 주소는 인증서에 없기 때문입니다. 접속 주소와 맞는 인증서를 LXC가 신뢰하게 되면 `0`으로 바꾸세요.
- **다운로드**: Release 파일은 `SHA256SUMS`로 확인합니다. 둘 다 같은 GitHub Release에서 오기 때문에, 깨진 다운로드는 잡지만 저장소 자체가 변조된 경우까지는 못 막습니다. 그래서 Release 파일마다 빌드 출처 증명(attestation)을 붙여 두었습니다. `gh attestation verify <파일> -R combatreadiness/proxmox-iac-bootstrap`으로 확인할 수 있습니다. LXC 템플릿은 `pveam`을 통해, OpenTofu는 서명된 apt 저장소를 통해 받습니다.

## 알려진 제약

- 단일 노드만 지원합니다.
- `PVE_TLS_INSECURE=1`이 기본값입니다 (위 참고).
- OpenTofu Role에 아직 `Sys.Modify`, `User.Modify`, `Datastore.Allocate` 같은 넓은 권한이 들어 있습니다. 줄이려면 실제 OpenTofu 코드로 한 번 더 검증해야 합니다.
- `pvesh set /cluster/sdn`은 여기서 만든 것뿐 아니라 클러스터의 대기 중인 SDN 변경을 전부 적용합니다.
- OpenTofu는 설치 시점에 apt 저장소에 있는 버전이 설치됩니다.
- 스토리지는 목록에서 고르지 않고 직접 입력합니다.

## 라이선스

Apache-2.0. [LICENSE](LICENSE)를 보세요.
