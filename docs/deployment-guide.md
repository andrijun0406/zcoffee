# Deployment Guide — Six-Stage Runbook (Jakarta 01)

Config-driven: every value lives in `scripts/powershell/config/lab-config.psd1`; parameters override
per run. All stages share `ui-common.ps1` (colored steps, per-stage log under `logs/`).

> Full problem/fix history: `deployment-journey.md`. Symptom lookup: `troubleshooting.md`.

## Where to run each stage
- **Stage 1 (OS deploy):** from the **jump host inside 10.8.230.0/24** (`10.8.230.221`). The Sangfor
  VPN cannot carry iDRAC->PC boot streaming reliably; the jump host serves the ISO on the DC LAN.
- **Stages 2-6:** from the jump host (or any host with WinRM to the nodes + Az PowerShell for 4/5).

## Tooling prerequisites
- Dell RACADM (iDRAC Tools) — install on Server Core with full path + `/qn`, **drop `ADDLOCAL`**.
- Windows ADK **oscdimg** — to build the slipstream ISO (IMAPI2 is unreliable/absent on Core).
- Az PowerShell (`Az.Accounts`, `Az.Resources`) — Stages 4-5.
- Inbound **TCP 8080** allowed on the serving host (ISO HTTP). No Python needed (native server).
- Golden ISO under `isos/` (gitignored).

---

## Pre-deployment
- Register Partner Admin Link (PAL) for Azure solutions.
- Cabling: **25GbE back-to-back** for storage (`SLOT 2 Port 1/2`, QLogic QL41262); **QL41232 rNDC**
  ports to the ToR for management/compute (negotiate 10GbE on the current switch).
- VLAN / IP layout (VLAN 230 is **tagged**, not native):
  - VLAN 230 -> Management/Compute (`10.8.230.0/24`)
  - VLAN 711 -> StorageNetwork1 (SLOT 2 Port 1)
  - VLAN 712 -> StorageNetwork2 (SLOT 2 Port 2)
- Validate firmware/drivers/BIOS against the Dell Support Matrix (14G-15G HCI); record versions in
  the private runbook. Ensure **Secure Boot is enabled** before Stage 5.

---

## Stage 1 — OS deployment (unattended, hands-off)

Build the slipstream ISO (answer file baked into the golden ISO -> single RFS mount):
```powershell
.\make-golden-with-unattend.ps1 -AutoSelectBootDisk -BakeNetworkConfig `
  -GoldenIso ..\..\isos\AzureLocal...A01.en-us.iso `
  -OutputIso ..\..\isos\AzureLocal-auto.iso
```
What the ISO does at install time:
- **WinPE `bootselect.cmd`** (cmd/wmic/diskpart — no PowerShell in WinPE): finds the boot disk by
  model `DELLBOSS VD`, partitions it (EFI/MSR/Windows), Setup skips the disk screen.
  Safety: exact model match, first-valid-index-then-stop, never guesses; identity match trusted at
  any size; falls through to manual selection if no unique BOSS.
- **Post-install `$OEM$` -> `SetupComplete.cmd` -> `netbootstrap.ps1`** (full OS, PowerShell exists):
  service tag -> hostname/IP from config, MAC-based adapter match, VLAN 230 tag, static IP/DNS,
  WinRM (+`Test-WSMan` validation), RDP, `C:\Bootstrap\success.txt`, then reboot.

Deploy a node (single-RFS, from the jump host):
```powershell
# optional clean boot VD first:
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -RecreateBossVd `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' -NoCertWarn
# install:
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -HttpHost 10.8.230.221 `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
  -ISOFile ..\..\isos\AzureLocal-auto.iso -StartInstallation -NoCertWarn
```
Verify: `Test-NetConnection 10.8.230.235 -Port 5985` (and 3389) return True; check
`netbootstrap.log` + `success.txt`.

> Do NOT mount a second RFS image — it blocks the golden ISO from booting on this firmware.
> Keep the ISO-server window open until install completes.

---

## Stage 2 — Host network readiness (validation-only)
Switchless Network ATC intents (SET switch, storage vNICs, RDMA/iWARP, VLANs, storage auto-IP) are
created by the **Stage 5 cloud deployment**, not here. Stage 2 validates over WinRM:
```powershell
.\bootstrap-cluster.ps1 -Stage 02-configure-network -ConfigureTrustedHosts -Transport HTTP
```
Checks: adapter names match config (incl. spaces), link/speed, RDMA capability, no pre-existing SET
team, hostname/IP. `-Apply` can repair base mgmt config (hostname/DNS/static IP; VLAN gated behind
`-ApplyVlanTag`) but never creates intents.

---

## Stage 3 — Node preparation + Environment Checker
```powershell
.\bootstrap-cluster.ps1 -Stage 03-prepare-node -ConfigureTrustedHosts -Transport HTTP -ConnectivityOnly
# or full readiness with safe repairs:
.\bootstrap-cluster.ps1 -Stage 03-prepare-node -ConfigureTrustedHosts -Transport HTTP -Apply
```
Validates time sync, roles (Hyper-V/Failover-Clustering/DCB), TPM 2.0, **Secure Boot** (re-enable
before Stage 5), BitLocker readiness, SBE staged in `C:\SBE`, pending reboot, Azure egress (443),
and runs the **Azure Local Environment Checker** (`AzStackHci.EnvironmentChecker`). `-Apply` only does
safe repairs (enable w32time, install a missing feature/module).

---

## Stage 4 — Azure Arc registration
Prereq: `Install-Module Az.Accounts, Az.Resources -Scope CurrentUser` on the runner.
```powershell
# read-only prerequisite check:
.\bootstrap-cluster.ps1 -Stage 04-register-arc -ArcMode Validate `
  -SubscriptionId <sub> -TenantId <tenant> -Region southeastasia -ConfigureTrustedHosts -Transport HTTP
# actual onboarding (reboots nodes during agent phase):
.\bootstrap-cluster.ps1 -Stage 04-register-arc -ArcMode Register -Apply -UseExistingAzLogin `
  -SubscriptionId <sub> -TenantId <tenant> -Region southeastasia -ConfigureTrustedHosts -Transport HTTP
```
Registers providers, ensures the RG, acquires tokens on the runner, then runs
`Invoke-AzStackHciArcInitialization` per node over WinRM. Gate for Stage 5: both nodes `Connected`.

---

## Stage 5 — Azure Local deployment (ARM)
Uses Az PowerShell (reuses Stage 4 login). Pre-flight gates: RG exists, both Arc nodes Connected,
`arcNodeResourceIds` resolve, adapter names match config, secrets not committed. Validate is default;
Deploy needs `-DeploymentMode Deploy -EnableDeployment` and a typed `DEPLOY`.
```powershell
.\bootstrap-cluster.ps1 -Stage 05-deploy-azure-local `
  -SubscriptionId <sub> -TenantId <tenant> -Region southeastasia `
  -TemplateFile ..\arm-templates\azuredeploy.json `
  -ParameterFile ..\arm-templates\ODIN-parameters.json -UseExistingAzLogin
```
`localAdminUserName`/`localAdminPassword` are injected as runtime overrides (prompted); the param file
keeps placeholders. Needs the Microsoft/Dell-provided `azuredeploy.json` template in `arm-templates/`.

---

## Stage 6 — Cluster validation
```powershell
.\bootstrap-cluster.ps1 -Stage 06-validate-cluster
```
Confirms cluster object, node membership/state, quorum (Cloud Witness), and S2D health.

---

## Post-deployment
- Apply SBE packages via LCM; manage with Dell OpenManage Integration for Windows Admin Center.
- Delete `C:\Windows\Panther\unattend.xml` on each node (contains the obfuscated admin password).
- Keep credentials, tenant/subscription IDs, and firmware versions in the private runbook.
