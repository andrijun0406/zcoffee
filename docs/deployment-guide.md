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
- **Azure service principal** (for unattended Stages 4-5) — see "Service principal" below.
- Inbound **TCP 8080** allowed on the serving host (ISO HTTP). No Python needed (native server).
- Golden ISO under `isos/` (gitignored).

---

## Service principal (unattended Azure auth for Stages 4-5)

Stages 4 (Arc) and 5 (deploy) sign in via `Connect-AzForStage` (in `ui-common.ps1`) with this
precedence: **SP secret -> SP certificate -> managed identity -> `-UseExistingAzLogin` -> device-code**.
For zero-touch, create a service principal once and pass `-ServicePrincipalId`/`-ServicePrincipalSecret`
(or `-ServicePrincipalCertThumbprint`). Without those, and with `-UseExistingAzLogin`, the stage reuses
the interactive session instead.

Create it (as Owner or User Access Administrator on the subscription):
```powershell
Connect-AzAccount -TenantId <tenant>
$sub = '<subscription-id>'; Set-AzContext -Subscription $sub
$sp = New-AzADServicePrincipal -DisplayName 'zcoffee-azlocal-deployer'
$appId = $sp.AppId; $secret = $sp.PasswordCredentials.SecretText   # secret shown ONCE
$scope = "/subscriptions/$sub"
New-AzRoleAssignment -ApplicationId $appId -RoleDefinitionName 'Azure Connected Machine Onboarding' -Scope $scope
New-AzRoleAssignment -ApplicationId $appId -RoleDefinitionName 'Azure Connected Machine Resource Administrator' -Scope $scope
New-AzRoleAssignment -ApplicationId $appId -RoleDefinitionName 'Contributor' -Scope $scope
New-AzRoleAssignment -ApplicationId $appId -RoleDefinitionName 'User Access Administrator' -Scope $scope
```
Roles: **Onboarding** (register Arc servers), **Resource Administrator** (manage Arc machine
resources), **Contributor** (create RG + deployment resources), **User Access Administrator**
(Azure Local deployment assigns roles to the cluster managed identity — fails without it).
Store `appId`/`secret` in the private runbook or a secret store; never commit them. Prefer an SP
**certificate** over a secret for the fully unattended orchestrator. For least privilege, scope the
assignments to `azljkt01rg` once it exists.

---

## Current validated 2608 path

The latest verified path uses the Microsoft Azure Portal 2608 image `AzureLocal24H2.26100.32230.LCM.12.2608.0.3020.x64.en-us.iso`. The embedded WIM reports OS build `26100.33296`; the image also contains Azure Local SBE/LCM payload `10.2608.1003.2003`. It does not populate the Dell `C:\SBE` staging directory, so ZCOFFEE stages the Dell AX-15G SBE bundle before Arc registration.

The Dell bundle used in the lab is `SBE_Dell_AX-15G_5.0.2606.1510` with its discovery XML and ZIP payload. This is an AX-650-equivalent lab experiment on PowerEdge R650 hardware, not a Dell-supported R650 deployment.

The validated pre-deployment gates are:

* OS deployment on both nodes.
* Combined Stage 2+3 network and readiness validation.
* SBE staging and verification on both nodes.
* Stage 4 Arc registration and gateway association.
* Stage 5 ARM Validate.

Only Stage 5 Deploy remains before Stage 6 cluster validation.

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

## SBE staging

Stage 3 reports whether `C:\SBE` exists, but the dedicated `stage-sbe.ps1` gate is the authoritative staging operation. It accepts a local jump-host source first and can be extended with a direct HTTPS download source.

```powershell
.\stage-sbe.ps1 `
  -NodeIPs '10.8.230.232','10.8.230.235' `
  -SbeSourcePath 'C:\zcoffee\sbe\AX650-2606\contents' `
  -Apply `
  -ReplaceRemoteSbe
```

The expected contents are two XML manifests and one ZIP payload. ZCOFFEE copies and verifies these files; Azure Local/LCM applies the SBE during Stage 5 deployment. Do not treat Azure Update Manager as the initial deployment mechanism.

## Stage 4 — Azure Arc registration
Prereq: `Az.Accounts`, `Az.Resources`, and the node-side `AzSHCI.ARCInstaller`. Register mode installs missing node modules.

```powershell
$gwId = (Get-Content .\config\arc-gateway.local.json -Raw | ConvertFrom-Json).resourceId

# idempotent validation/association using the existing Azure context:
.\04-register-arc.ps1 -Mode Register -Apply `
  -NodeIPs '10.8.230.232','10.8.230.235' `
  -SubscriptionId $sub -TenantId $tenant `
  -AccountId '7d1ef683-a16c-4079-abb2-3038ba77ffbe' `
  -UseArcGateway -ArcGatewayID $gwId -UseExistingAzLogin
```

Stage 4 creates or reuses the Arc Gateway, stages the node-side registration modules, associates existing machines through the supported settings endpoint, and verifies exact Arc status plus gateway mode. The installed `AzSHCI.ARCInstaller 1.2408.0.3053` does not expose `TargetSolutionVersion`; partner metadata is therefore diagnostic rather than a hard gate in this lab. The operational gate for Stage 5 is: every node is Azure-side `Connected`, local `azcmagent` status is exactly `Connected`, and gateway mode is `gateway` when enabled.

---

## Stage 5 — Azure Local deployment (ARM)
Uses Az PowerShell and the validated ODIN template/parameter pair. Pre-flight gates include the resource group, Arc machine IDs, exact adapter names, gateway association, SBE staged under `C:\SBE`, and runtime secret injection. `Validate` is non-mutating; Deploy requires `-DeploymentMode Deploy -EnableDeployment` and a typed `DEPLOY`.

```powershell
$template = (Resolve-Path ..\arm-templates\odin-template.json).Path
$params   = (Resolve-Path ..\arm-templates\odin-parameters.json).Path
$gwId     = (Get-Content .\config\arc-gateway.local.json -Raw | ConvertFrom-Json).resourceId

# non-mutating ARM validation:
.\05-deploy-azure-local.ps1 -DeploymentMode Validate `
  -SubscriptionId $sub -TenantId $tenant -ResourceGroupName 'azljkt01rg' `
  -TemplateFile $template -ParameterFile $params `
  -UseArcGateway -ArcGatewayID $gwId -UseExistingAzLogin `
  -LocalAdminUser 'Administrator' -LocalAdminPassword $cred.Password

# real deployment after Validate and What-If review:
.\05-deploy-azure-local.ps1 -DeploymentMode Deploy -EnableDeployment `
  -SubscriptionId $sub -TenantId $tenant -ResourceGroupName 'azljkt01rg' `
  -TemplateFile $template -ParameterFile $params `
  -UseArcGateway -ArcGatewayID $gwId -UseExistingAzLogin `
  -LocalAdminUser 'Administrator' -LocalAdminPassword $cred.Password `
  -DeploymentName 'azljkt01dep2608'
```

The script uses `TemplateParameterObject`, preserves single-item arrays such as `dnsServers`, and injects the local admin password only at runtime. It does not inject unsupported Arc Gateway parameters into the current template; Stage 4 association is authoritative for gateway use.

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
