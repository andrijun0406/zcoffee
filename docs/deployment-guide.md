# Deployment Guide

This guide maps the six-stage automation to the Dell AX System for Azure Local (switchless networking) and Microsoft Azure Local deployment flow. Every stage uses the shared `ui-common.ps1` dashboard (colored steps, progress, warnings/errors, elapsed time, per-stage log under `logs/`, optional `-UseGui` window).

> [!NOTE]
> For the chronological problem-and-fix account of the Stage 1 bring-up (what each
> attempt ruled in or out, and why the design ended up as single-RFS + slipstreamed
> answer file), see [`deployment-journey.md`](./deployment-journey.md).

## Table of contents

- [Supportability and scope](#supportability-and-scope)
- [Pre-deployment](#pre-deployment)
- [Configuration source of truth](#configuration-source-of-truth)
- [Tooling prerequisites](#tooling-prerequisites)
- [Running from a jump host (VPN / Server Core)](#running-from-a-jump-host-vpn--server-core)
- [Stage 1 — OS deployment](#stage-1--os-deployment-01-deploy-osps1)
- [Stage 2 — Host network readiness + base management config](#stage-2--host-network-readiness--base-management-config-02-configure-networkps1)
- [Stage 3 — Node preparation](#stage-3--node-preparation-03-prepare-nodeps1)
- [Stage 4 — Azure Arc registration](#stage-4--azure-arc-registration-04-register-arcps1)
- [Stage 5 — Azure Local deployment](#stage-5--azure-local-deployment-05-deploy-azure-localps1)
- [Stage 6 — Cluster validation](#stage-6--cluster-validation-06-validate-clusterps1)
- [Post-deployment](#post-deployment)
- [Best practice](#best-practice)

## Supportability and scope

> [!WARNING]
> Treat R650 as **lab-only** until Dell confirms the exact R650 support-matrix row (platform + NIC + firmware + OS + SBE). See [`lab-architecture.md`](./lab-architecture.md).

- Identity: Local Identity with Azure Key Vault (AD-less).
- Storage: switchless, 2-node, dual 25GbE back-to-back.

## Pre-deployment

- Register a Partner Admin Link (PAL) for Azure solutions.
- Verify cabling: 25GbE back-to-back for storage (QLogic QL41262, SLOT 2 Port 1/2), 25GbE to the ToR switch for management/compute (QLogic QL41232 rNDC, Integrated NIC1 Port 1-1/2-1).
- Confirm VLAN/IP layout:
    - VLAN 230 → Management/Compute (`10.8.230.0/24`)
    - VLAN 711 → StorageNetwork1 (SLOT 2 Port 1)
    - VLAN 712 → StorageNetwork2 (SLOT 2 Port 2)
- Firmware/software compliance: validate against the Dell Support Matrix and record BIOS/NIC/driver/SBE versions in the private runbook. Update all nodes before OS deployment.

## Configuration source of truth

> [!IMPORTANT]
> All values (DNS, VLANs, gateway, cluster/resource names, node and iDRAC IPs, HTTP port, local admin) are defined once in `config/lab-config.psd1` (under `scripts/powershell/`) and loaded by every stage. Passing a parameter overrides the config for that run. Compare `lab-config.psd1` with [`odin-config-report.md`](./odin-config-report.md) before deployment.

## Tooling prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+, run as Administrator.
- Dell RACADM on PATH or via `-RACADMPath`.
- No Python needed. The Golden Image ISO is served by a native PowerShell HTTP server (`serve-iso.ps1`, uses .NET HttpListener) that Stage 1 launches automatically.
- Inbound firewall rule for the ISO server port. The iDRAC pulls the ISO from this PC over TCP 8080, so an inbound Allow rule is REQUIRED. Stage 1 preflight now checks for it and fails fast with the fix command if missing. Create it once per PC:

    ```powershell
    New-NetFirewallRule -DisplayName 'AzureLocal ISO 8080' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080
    ```

    > [!IMPORTANT]
    > Without this rule, the `remoteimage` connect half-opens and the NEXT attempt fails with `RAC0718: Remote File Share service is busy`. See troubleshooting.
- Az PowerShell modules `Az.Accounts` and `Az.Resources` on the jump host for Stages 4-5 (`Install-Module Az.Accounts,Az.Resources -Scope CurrentUser`). Azure CLI is not required.
- Keep the Golden Image ISO under `isos/` (gitignored). Never commit ISOs.
- For hands-off installs, bake the answer file INTO the golden ISO with `make-golden-with-unattend.ps1` (single RFS mount). Do NOT mount a separate Autounattend ISO as a second RFS device — see the single-RFS note below.
- `make-golden-with-unattend.ps1` requires **oscdimg.exe** (Windows ADK "Deployment Tools"). It is a single ~2 MB binary; install the ADK feature or copy just `oscdimg.exe` to the build host and pass `-OscdimgPath`. The script auto-detects it on PATH and in the default ADK location.

## Stage 1 — OS deployment (`01-deploy-os.ps1`)

Runs `preflight-os.ps1`, starts the ISO HTTP server bound to a reachable management IP, then calls `deploy-os.ps1` for each iDRAC.

```powershell
# Mount only (safe)
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.225 -NoCertWarn

# Mount + one-time VCD-DVD boot + power-cycle, with GUI
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.225 `
  -StartInstallation -NoCertWarn -UseGui
```

> [!NOTE]
> - The ISO server must bind to an IP both iDRACs can reach; loopback/wildcard is rejected.
> - Use `-ExpectedISOHash <sha256>` to enforce image integrity.

### Optional hardware preparation (runs before OS install)

Stage 1 can bring each node to a known-good state first, via `prepare-hardware.ps1`. These run per node, after the credential prompt and before the ISO server starts. All are opt-in.

- `-FirmwareCheckOnly` — non-destructive. Compares installed firmware against the catalog and prints an installed-vs-available report (`racadm update ... --verifycatalog` + `update viewreport`). Nothing is applied.
- `-UpdateFirmware` — applies updates from the catalog (`-a FALSE`, no downgrades). Reboots the node and tracks the job to completion.
- `-UpdateBios` — applies a SINGLE BIOS DUP only (`-BiosDupFile` + `-BiosRepoUrl`), not the whole catalog. Use this to refresh just the BIOS and its Secure Boot certificate store — enough to fix the "Boot Failed: Virtual Optical Drive" issue — without pushing NICs/backplane/disks past the support matrix. Reboots the node and tracks the job.
- `-CatalogUrl <host>` — HTTPS catalog host. Defaults to `FirmwareCatalogUrl` in `config/lab-config.psd1`.
- `-RecreateBossVd` — DESTRUCTIVE. Discovers the BOSS controller (reads the M.2 SSDs as `Disk.Direct.*` on the AHCI controller), deletes existing VD(s), and creates a fresh RAID-1 boot VD named `OS`, committing via a power-cycle config job. Supplying the flag is the confirmation — it proceeds without prompting on every targeted node.
- `-DisableSecureBoot` / `-EnableSecureBoot` — set UEFI Secure Boot state via a BIOS config job + reboot. Disable as a temporary install workaround on old BIOS; re-enable after a BIOS update (Secure Boot is required for the validated cluster). BootMode stays UEFI.
- `-OnlyNode <iDRAC-IP | name | host-IP>` — scope the entire stage (preflight, hardware prep, mount, boot) to a single node. Omit to target all nodes from config.

```powershell
# Check firmware only (safe, no changes)
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 2.2.2.4 -FirmwareCheckOnly -NoCertWarn

# Full redeploy prep: update firmware, then recreate the BOSS boot VD, then mount + install
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 2.2.2.4 `
  -UpdateFirmware -RecreateBossVd -StartInstallation -NoCertWarn
```

> [!WARNING]
> `-RecreateBossVd` wipes the OS boot volume on every targeted node. There is no prompt — the flag itself is the confirmation. Use `-OnlyNode` to limit the blast radius to one node. It only touches the BOSS boot pair; the PERC data/cache disks are untouched.

> [!IMPORTANT]
> Firmware from `downloads.dell.com` is always-latest and can exceed the Dell Azure Local support matrix. For strict compliance, point `-CatalogUrl` at a Dell Repository Manager catalog pinned to the validated versions, and record the applied versions in the private runbook. Firmware update requires the iDRAC to have outbound HTTPS to the catalog host.

### Secure Boot and the Golden Image boot failure

On very old BIOS, UEFI Secure Boot can reject the newly-signed Golden Image bootloader, so the node reports `Boot Failed: Virtual Optical Drive` even when the drive is selected manually via F11. Disable Secure Boot as a temporary workaround, install, then re-enable it after a BIOS update (Azure Local requires Secure Boot for the validated cluster). Note: on this lab a BIOS update from 1.4.4 to 1.12.1 did NOT by itself resolve the boot failure — the actual root cause was a second RFS image blocking boot (see the single-RFS note below).

```powershell
# Temporarily disable Secure Boot on a node
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -DisableSecureBoot -NoCertWarn

# Install (single RFS mount; unattended golden ISO)
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 2.2.2.4 -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn

# After the OS is installed and BIOS updated, re-enable Secure Boot
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -EnableSecureBoot -NoCertWarn
```

> [!CAUTION]
> Do not run a second (mount-only) bootstrap while an install is in progress — it detaches remote media on all targeted nodes, which pulls the media out from under Windows Setup (Setup then asks for a "media driver"). Keep one bootstrap window open until the node reaches first reboot. Re-enable Secure Boot before Stage 5 — Azure Local requires it.

### Single-RFS mount and the unattended golden ISO

On R650 BIOS 1.12.1, mounting a SECOND iDRAC RFS image (`racadm remoteimage2`, e.g. a separate Autounattend ISO) prevents the golden ISO on RFS1 from enumerating as a bootable UEFI device. In the F11 boot menu only "Virtual Network File 2" appears; "Virtual Network File 1" (the golden ISO) is absent, and the node cannot boot the installer. This was the true root cause of the repeated boot failures — not the Sangfor VPN, not Secure Boot, and not the HTTP server (the jump-host test on the DC LAN failed the same way until RFS2 was removed).

The fix is a single RFS mount with the answer file slipstreamed into the golden ISO:

```powershell
# 1. Build an unattended golden ISO (bakes Autounattend.xml into the ISO root; single bootable image)
.\make-golden-with-unattend.ps1 `
  -GoldenIso ..\..\isos\AzureLocal24H2.<...>_A01.en-us.iso `
  -OutputIso ..\..\isos\AzureLocal-unattend.iso

# 2. Deploy with ONE RFS mount (no RFS2). Fully unattended, including automatic BOSS disk selection.
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost <server-ip> `
  -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn
```

`make-golden-with-unattend.ps1` repacks the ISO with **oscdimg**: it mounts the golden ISO, robocopies the tree to a staging folder, drops `Autounattend.xml` at the root, and rebuilds with UDF (the install image inside can exceed the 4 GB ISO9660 limit) plus the BIOS+UEFI El Torito boot catalog (`efisys_noprompt.bin`, which also removes the "Press any key to boot" prompt). IMAPI2 was tried first but fails on large dual-boot Windows media (error `0xC0AAB132` in `CreateResultImage`) and is not registered on Server Core — oscdimg is the reliable, Microsoft-supported path. Building needs free disk ~2x the ISO size (staging + output). Validate the first output by booting one node before relying on it for both.

### Boot-disk selection

`make-golden-with-unattend.ps1` runs hands-off through language/locale/timezone/password. Disk selection has two modes:

- **Interactive (default, proven):** Setup pauses only at the disk screen; the operator picks the BOSS RAID-1 `OS` volume (~223 GB on R650). Used successfully on both nodes.
- **Automatic (`-AutoSelectBootDisk`):** a WinPE `RunSynchronous` step detects the BOSS RAID-1 VD by **controller identity** (its disk enumerates with a `BOSS` friendly name — model-agnostic, no size to configure), then `diskpart` cleans it and creates the UEFI/GPT layout; Setup installs via `InstallToAvailablePartition`. If detection is ambiguous (0 or >1 candidates) it exits non-zero and stops **before touching any disk**, so it can never wipe an S2D data disk. Element order in the answer file must be `ImageInstall` → `RunSynchronous` → `UserData`, or Setup rejects the whole file (`0x80070001 - 0x4003x`). Tuning: `-BootDiskModelMatch` (default `(?i)boss`), `-BootDiskMaxSizeGB` (ceiling for the smallest-disk fallback only).

### Baked-in network + remote access (`-BakeNetworkConfig`)

A fresh install otherwise comes up with **no IP** (APIPA only), reachable solely via the iDRAC console. `-BakeNetworkConfig` injects a `specialize`-pass script that makes each node self-configure and become remotely reachable — no console work:

- Reads the node's **Dell service tag** (`Win32_SystemEnclosure.SerialNumber`) and matches it to `lab-config.psd1` `Nodes` (ServiceTag → Name + HostIP). For this lab: `JF7C7J3 → azljkt01n1 / 10.8.230.232`, `1G7C7J3 → azljkt01n2 / 10.8.230.235`.
- Sets the **hostname**, tags **VLAN 230** on the management adapter (`Integrated NIC 1 Port 1-1`), sets **static IP / gateway 10.8.230.1 / DNS 10.8.230.51** (/24), and enables **WinRM + RDP** (profile set Private).
- All values come from `lab-config.psd1` (gateway, DNS, VLAN, mgmt adapter, per-node IP/tag) — the single source of truth. `-MgmtPrefixLength` overrides the /24 default.
- The specialize script logs to `C:\Windows\Temp\netbootstrap.log` on the node; if the service tag has no mapping it leaves networking unchanged and exits cleanly.

Combined fully-automated build + install (both features):

```powershell
# On the build/jump host (needs oscdimg + lab-config.psd1 in scripts/powershell/config)
.\make-golden-with-unattend.ps1 -AutoSelectBootDisk -BakeNetworkConfig `
  -GoldenIso ..\..\isos\AzureLocal24H2.<...>_A01.en-us.iso `
  -OutputIso ..\..\isos\AzureLocal-auto.iso

.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -HttpHost <server-ip> `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
  -ISOFile ..\..\isos\AzureLocal-auto.iso -StartInstallation -NoCertWarn
```

After install the node should be reachable: `Test-NetConnection <node-ip> -Port 5985` and RDP on 3389 — verify with Stage 2/3 over WinRM instead of the iDRAC console.

> [!IMPORTANT]
> Both `-AutoSelectBootDisk` and `-BakeNetworkConfig` are answer-file automation that has NOT been validated end-to-end on the Azure Local golden image (the interactive/manual-network path is what installed both current nodes). Test the combined ISO on ONE node first — .86 is the safe test node since reimaging it is non-destructive until the cluster exists. Watch its console: no disk prompt = auto-select worked; after it settles, confirm WinRM/RDP reachability from the jump host. Keep an interactive ISO as fallback.

> [!NOTE]
> The `01-deploy-os.ps1` worker no longer mounts a second RFS image at all; it actively clears any stale RFS2 before mounting RFS1. The older `make-autounattend-iso.ps1` (separate RFS2 ISO) is deprecated — use `make-golden-with-unattend.ps1` instead.

## Running from a jump host (VPN / Server Core)

If the management PC reaches the datacenter only over a client VPN (Sangfor), the iDRAC must
open a connection *back* to that PC to pull the ISO. That reverse path was not the cause of
the boot failures on this lab (see [`deployment-journey.md`](./deployment-journey.md)), but a
jump host inside `10.8.230.0/24` is still the most robust place to serve the ISO — LAN-speed,
low-latency, no VPN in the read path. The jump host here is **Windows Server Core**, which has
a few gotchas worth capturing.

### Getting the scripts and ISO onto the jump host

- **Scripts:** clone the repo and `git pull` to sync. The clone is the runtime copy; edits are
  made elsewhere and pulled here. This avoids the stale-copy drift that partial manual copies
  caused during bring-up.

    ```powershell
    git clone https://github.com/andrijun0406/zcoffee.git C:\zcoffee
    cd C:\zcoffee ; git pull        # after every change
    ```

- **Golden ISO:** it is gitignored (too large for Git), so it does **not** arrive via `git pull`.
  Do **not** try to push the ~8 GB ISO across the VPN — both common paths fail:
    - RDP drive redirection (`\\tsclient\...`) aborts on large files (`ERROR 995`, I/O aborted)
      and is very slow.
    - The admin share `\\host\C$` is blocked for local accounts by default
      (`ERROR 1326`, bad username/password) due to UAC remote restrictions.
- **Best approach — build the ISO on the jump host.** The golden ISO is already on the jump
  host (it is what you boot from), so you only need to copy the ~2 MB `oscdimg.exe` (fine over
  RDP), then run `make-golden-with-unattend.ps1` locally. Nothing large crosses the VPN.

    If you must copy the 8 GB ISO instead, either enable local-account admin-share access on the
    jump host (`LocalAccountTokenFilterPolicy = 1`) and robocopy to `C$`, or create a normal
    share (`New-SmbShare -Name isodrop -Path C:\zcoffee\isos -FullAccess Administrator`) and copy
    to that.

### Installing RACADM on Server Core

RACADM ships in **Dell iDRAC Tools for Windows** (`iDRACTools_x64.msi`). On Server Core:

```powershell
# Use an ABSOLUTE path and /qn. A relative ".\" path fails with MSI error 1324;
# /qf (full UI) can misbehave on Core.
msiexec.exe /i "C:\Dell\iDRACTools_x64.msi" /qn /norestart /l*v C:\Dell\racadm-install.log

# Do NOT pass ADDLOCAL=RACADM — "RACADM" is not a valid feature name in this MSI and
# aborts with "Error 2711 ... Feature name ('RACADM') not found" -> 1603. The default
# install includes RACADM.

& 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' version
```

If `racadm` is not recognized in a shell, it is just a PATH issue for that session — either add
`C:\Program Files\Dell\SysMgt\iDRACTools\racadm` to PATH (new shell), or pass the full path via
`-RACADMPath`. The scripts and preflight already probe the default install location.

### PowerShell edition on Server Core

If the jump host only has **Windows PowerShell 5.1**, its `Invoke-WebRequest` tries to use the
Internet Explorer parsing engine, which Server Core lacks
(`The response content cannot be parsed because the Internet Explorer engine is not available`).
The scripts pass `-UseBasicParsing` to avoid this (a no-op on PowerShell 7). Installing
PowerShell 7 (`pwsh`) on the jump host keeps it consistent with the primary PC and avoids other
5.1/Core quirks (for example, IMAPI2 COM is often unregistered on Core — one more reason the ISO
build uses oscdimg, not IMAPI2).

### Then run Stage 1 on the jump host

```powershell
cd C:\zcoffee\scripts\powershell
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.221 `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
  -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn
```

## Stage 2 — Host network readiness + base management config (`02-configure-network.ps1`)

Two roles. On a switchless 2-node deployment the SET switch, storage vNICs, RDMA/iWARP, and storage auto-IP are created by the Azure Local **cloud deployment in Stage 5** (ARM `intentList` / `storageNetworkList`) — creating those here would collide with it. So Stage 2 **validates readiness** for the intents Stage 5 will build, and can optionally **apply/repair the base management config** on the physical management port so the nodes are reachable and can reach Azure for Arc registration.

Connects to each node over **WinRM** with an explicit local admin credential (AD-less / Local Identity).

### Validation (default, read-only)

- Physical adapter **names** match `lab-config.psd1` — the exact names Stage 5's ARM targets: `Integrated NIC 1 Port 1-1` / `Port 2-1` (mgmt/compute, QLogic QL41232) and `SLOT 2 Port 1` / `Port 2` (storage, QLogic QL41262).
- Link state and speed (storage adapters Up @ 25 Gbps, media connected = back-to-back cable present).
- Storage adapters **RDMA-capable** (iWARP); RDMA not yet *enabled* pre-deploy is expected — Stage 5 enables it.
- **No pre-existing SET team / storage vNICs** that would conflict with the cloud deployment.
- Hostname and management IP match the config; required roles (Hyper-V, Failover-Clustering, DCB) noted.

```powershell
# From the jump host. AD-less: uses a local admin credential + WinRM.
.\bootstrap-cluster.ps1 -Stage 02-configure-network -ConfigureTrustedHosts -Transport HTTP
# HTTPS (if an HTTPS WinRM listener exists on the nodes):
.\bootstrap-cluster.ps1 -Stage 02-configure-network -ConfigureTrustedHosts -Transport HTTPS -SkipCertCheck
```

- `-ConfigureTrustedHosts` adds the node IPs to this host's WinRM TrustedHosts (the only local mutation) and tests connectivity first.
- `-Transport HTTP` uses 5985 (works AD-less with Negotiate + TrustedHosts). `-Transport HTTPS` uses 5986 and needs an HTTPS listener on the nodes; add `-SkipCertCheck` for a self-signed listener cert.
- Resolve any FAIL (missing adapter name, storage cable down) before Stage 5; WARN items (RDMA not yet enabled, features not yet installed) are expected pre-deploy.

### Base management config (`-Apply`, gated)

This is **temporary** bootstrap config on the physical management port. It sets base reachability so Arc/Stage 5 can run; Stage 5's Network ATC then builds the SET team and **migrates the management IP onto a `vManagement` vNIC**. So we deliberately set the IP on a single physical port here — not a manually-built team — to avoid colliding with the SET team the cloud deployment creates.

Ordered to be **connectivity-safe** over WinRM (nothing that would silently drop the session unless you force it):

1. **DNS** → set to `10.8.230.51` (safe).
2. **Hostname** → `Rename-Computer` to `azljkt01n1` / `azljkt01n2` if mismatched (needs a reboot; `-RebootIfRenamed` reboots automatically).
3. **Static IP / gateway** → idempotent. If the node already sits at its target IP, it just ensures static + prefix + gateway (no address change, no drop). If the current IP differs from the target, it **refuses** over WinRM (would drop the session) unless `-ForceIpChange`.
4. **VLAN 230 tag** → always **reported**; only changed with `-ApplyVlanTag` (risky — can drop the session; prefer the iDRAC console for VLAN changes).

```powershell
# Verify + repair hostname/DNS/static-IP on the running nodes (safe, idempotent)
.\bootstrap-cluster.ps1 -Stage 02-configure-network -ConfigureTrustedHosts -Transport HTTP -Apply -RebootIfRenamed
```

> [!CAUTION]
> VLAN 230 on this DC is **tagged** (the switch ports are trunked, VLAN 230 is not native — confirmed with the datacenter admin). If the OS is not tagging on the physical adapter, that tag lives at the switch today. Changing the host-side `VLAN ID` advanced property (`-ApplyVlanTag`) can drop the WinRM session — do VLAN changes from the iDRAC console. Confirm the required tagging model with your DC admin for any new environment.

> [!NOTE]
> For clean redeploys the same hostname + static IP can also be baked into the golden ISO's answer file (per-node, keyed on service tag). That path depends on the exact Windows adapter names on the installed nodes — run Stage 2 validation first to capture the real `Get-NetAdapter` names, then bake them in. Until then, `-Apply` on the already-running nodes is the reliable route.

## Stage 3 — Node preparation (`03-prepare-node.ps1`)

Guarded placeholder for hostname, DNS A records, the dedicated non-built-in local admin, security baseline, firmware/SBE readiness, and environment validation.

- Static management IPs: `azljkt01n1` → `10.8.230.232`, `azljkt01n2` → `10.8.230.235`.
- DNS forwarder: **`10.8.230.51`** (from `lab-config.psd1`).
- Security baseline: BitLocker (boot + data), Credential Guard, WDAC, SMB signing, drift control.

> [!CAUTION]
> Keep the ODIN report aligned with `lab-config.psd1`. DNS server IPs cannot change after deployment.

## Stage 4 — Azure Arc registration (`04-register-arc.ps1`)

Registers both nodes as Arc-enabled servers so the Stage 5 ARM template can target their `arcNodeResourceIds`. Validation-first (like Stages 2/3): Validate mode is read-only; Register mode (`-Apply`) performs the onboarding.

Flow: sign in to Azure on the jump host (device code) → register/verify the required resource providers → ensure the resource group + acquire ARM/Graph tokens → per node over WinRM, ensure `AzsHci.ARCInstaller` + Az modules and run `Invoke-AzStackHciArcInitialization` with the passed tokens (no interactive auth on the node) → verify each node shows `Status=Connected` and capture its resource id.

```powershell
# Read-only prerequisite check (no onboarding)
.\bootstrap-cluster.ps1 -Stage 04-register-arc -ArcMode Validate `
  -SubscriptionId <sub-id> -TenantId <tenant-id> -Region southeastasia `
  -ConfigureTrustedHosts -Transport HTTP

# Perform registration on both nodes
.\bootstrap-cluster.ps1 -Stage 04-register-arc -ArcMode Register -Apply `
  -SubscriptionId <sub-id> -TenantId <tenant-id> -Region southeastasia `
  -ConfigureTrustedHosts -Transport HTTP
```

Prerequisites before running Register: Stage 3 green, **Secure Boot re-enabled**, no pending reboot, and outbound HTTPS from each node to the Azure/Arc endpoints. Registration reboots the node when the agent update phase completes; re-runs are idempotent (already-Connected nodes are skipped). Copy the printed resource ids into `arcNodeResourceIds` for Stage 5.

> [!IMPORTANT]
> Subscription and tenant IDs are never stored in the repo. Pass them as parameters (or fill the private lab-config). The signed-in account needs permission to register providers, create the resource group, and onboard Arc machines.

## Stage 5 — Azure Local deployment (`05-deploy-azure-local.ps1`)

This is the stage that actually builds the cluster — SET switch, storage vNICs, RDMA/iWARP, storage auto-IP, Storage Spaces Direct, the failover cluster, and the Azure Local instance — all driven by the ARM template's `intentList` / `storageNetworkList`. It uses **Az PowerShell** (reusing the Stage 4 login on the jump host; no separate Azure CLI dependency).

Flow: validate tooling + files → establish Azure context → **pre-flight gates** → inject secrets at runtime → Validate (default) or What-If + typed `DEPLOY` + deploy.

Pre-flight gates (read-only; deployment is refused unless they pass):
- resource group exists (Stage 4 creates it),
- both Arc nodes exist and report `Status=Connected`,
- `arcNodeResourceIds` in the parameter file resolve to those machines,
- management adapter names in `intentList` match `lab-config.psd1` (the exact Windows names, e.g. `Integrated NIC 1 Port 1-1` — note the space),
- secrets are being injected at runtime, not read from the committed file.

Validate (non-mutating):

```powershell
.\bootstrap-cluster.ps1 -Stage 05-deploy-azure-local `
  -SubscriptionId <sub-id> -TenantId <tenant-id> -Region southeastasia `
  -TemplateFile ..\arm-templates\azuredeploy.json `
  -ParameterFile ..\arm-templates\ODIN-parameters.json -UseExistingAzLogin
```

Deploy (gated):

```powershell
.\bootstrap-cluster.ps1 -Stage 05-deploy-azure-local -DeploymentMode Deploy -EnableDeployment `
  -SubscriptionId <sub-id> -TenantId <tenant-id> -Region southeastasia `
  -TemplateFile ..\arm-templates\azuredeploy.json `
  -ParameterFile ..\arm-templates\ODIN-parameters.json -UseExistingAzLogin
```

Secrets: the stage prompts for the local admin password (account `Administrator` by default from `lab-config.psd1`) and injects `localAdminUserName` / `localAdminPassword` as runtime override parameters — the committed parameter file keeps placeholders. Never commit the real password.

> [!IMPORTANT]
> Before Deploy: Stages 2-4 green, both nodes **Arc-Connected**, **Secure Boot re-enabled**, no pending reboot, and the 25GbE storage DACs linked. The management adapter names in the ARM parameters were corrected to include the space (`Integrated NIC 1 Port 1-1`); a name mismatch fails the deployment when Network ATC cannot find the adapter. Verify `hciResourceProviderObjectID` matches your tenant.

> [!TIP]
> Two-node deployment requires a dedicated Cloud Witness storage account; use one Key Vault per cluster. The cloud deployment runs 1-3 hours — track it in the portal (Azure Local instance) or `Get-AzResourceGroupDeployment`. `-SkipArcCheck` exists only for re-runs after the Arc gate has already been confirmed.

## Stage 6 — Cluster validation (`06-validate-cluster.ps1`)

Confirms cluster object, node membership/state, quorum, and Storage Spaces Direct health.

## Post-deployment

- Apply SBE packages for Azure Local updates.
- Manage with Dell OpenManage Integration for Windows Admin Center; monitor Support Matrix compliance.
- Keep credentials and firmware versions in the private runbook.

## Best practice

> [!IMPORTANT]
> - No credentials, tenant IDs, subscription IDs, or secrets in the repo.
> - Cross-reference: "See private runbook for credentials and firmware versions."
