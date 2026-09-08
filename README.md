# zcoffee: Azure Local 2-Node Lab Deployment (Jakarta 01)


## Current status (Jakarta 01)

As of 2026-09-07, the clean Azure Local 2608 pre-deployment path is verified through ARM validation:

| Gate | State |
|---|---|
| OS deployment | PASS on both nodes using the Azure Portal 2608 ISO; WIM build `26100.33296` |
| Network/readiness | PASS via combined Stage 2+3 wrapper |
| Dell SBE | PASS; `SBE_Dell_AX-15G_5.0.2606.1510.xml`, discovery manifest, and ZIP staged to `C:\SBE` on both nodes |
| Arc registration | PASS and idempotent; both nodes `Connected` and `connection.type=gateway` |
| Arc Gateway | PASS; existing `zcoffee-arcgw` reused and associated with both nodes |
| Stage 5 Validate | PASS; ARM template validation completed without creating Azure Local |
| Stage 5 Deploy | NOT RUN; next irreversible gate |
| Stage 6 Cluster validation | Pending Stage 5 deployment |

The current deployment uses the ODIN template/parameter pair in `arm-templates/`. The template has no native Arc Gateway parameters, so Stage 4 associates the Arc machines with the gateway before Stage 5.
## Overview
Automation scripts and documentation to deploy a **2-node switchless Azure Local 24H2 cluster**
(Storage Spaces Direct, Hyper-V, Local Identity + Key Vault) on **Dell PowerEdge R650** over a
Sangfor VPN / jump-host connection to the datacenter.

The framework is a **six-stage, config-driven** workflow; the pre-deployment path can be operated as four gates by treating Stage 2+3 as one validation gate and Stage 6 as post-deployment. Every value lives once in
`scripts/powershell/config/lab-config.psd1` (the single source of truth); every stage reads it,
and any parameter can override it per run.

## Status (confirmed on real hardware)
- **Stage 1 (OS deploy): DONE and hands-off.** Unattended install with automatic BOSS boot-disk
  selection (WMIC/DiskPart in WinPE) and post-install network bring-up (hostname, VLAN 230,
  static IP, WinRM, RDP) via `$OEM$`/`SetupComplete.cmd`. Node `.235` (azljkt01n2) verified fully
  automated end-to-end; reachable on WinRM (5985) and RDP (3389) with no iDRAC console work.
- **Stages 2-4 (network validate / node prep / Arc): validated** (Validate mode green).
- **Stage 5 (ARM cloud deploy): built**, pending storage DAC cabling + Arc Register.
- **Stage 6 (cluster validation): built.**

External dependency remaining: **25GbE back-to-back storage cabling** from the DC team.

## Hardware reality (corrected from the original build sheet)
- rNDC is **QLogic QL41232 2x25GbE** (build sheet said Intel X710; `hwinventory` proved otherwise on both nodes). Management/compute ports negotiate at **10GbE** on the ToR.
- Storage NIC: **QLogic FastLinQ QL41262 2x25GbE** in **SLOT 2** (`SLOT 2 Port 1/2`).
- Boot: **Dell BOSS-S2** RAID-1 (~223 GB), enumerates as model **`DELLBOSS VD`**.

## Prerequisites
- 2 x Dell PowerEdge R650, iDRAC reachable.
- VLAN 230, subnet `10.8.230.0/24` (VLAN 230 is **tagged**, not native — host tags it on the mgmt adapter).
- Jump host **inside** `10.8.230.0/24` (see below — required for reliable OS boot streaming).
- Dell RACADM (iDRAC Tools) on the machine running Stage 1.
- Windows ADK **oscdimg** for building the slipstream ISO.
- Az PowerShell (`Az.Accounts`, `Az.Resources`) on the machine running Stage 4/5.
- Azure subscription (IDs kept in the private runbook, not the repo).

## Why a jump host (VPN reality)
The Sangfor client VPN is a one-way tunnel: your PC can reach the iDRACs, but the **iDRAC cannot
reliably stream the boot image back** to the PC's VPN IP during UEFI boot. OS install therefore
runs from a **jump host on the DC LAN** (`10.8.230.221`) that serves the ISO to the iDRACs
directly. See `docs/deployment-journey.md` for the full story.

## Repository layout
```
zcoffee/
|- README.md
|- deployment-handoff.md            # paste-in brief to resume in a fresh session
|- .gitignore                       # excludes isos/, logs/, real ODIN params, secrets
|- docs/
|  |- deployment-guide.md           # the six-stage runbook
|  |- deployment-journey.md         # chronological saga: every problem + fix (READ THIS)
|  |- lab-architecture.md           # hardware, network, naming
|  |- odin-config-report.md         # validated ODIN wizard output (real values)
|  |- troubleshooting.md            # symptom -> cause -> fix lookup
|- scripts/powershell/
   |- config/lab-config.psd1        # SINGLE SOURCE OF TRUTH
   |- bootstrap-cluster.ps1         # dispatcher
   |- ui-common.ps1                 # shared UI + config loader
   |- 01-deploy-os.ps1 ... 06-validate-cluster.ps1
   |- make-golden-with-unattend.ps1 # slipstream generator (auto BOSS + network bake)
   |- make-unattend-xml-only.ps1    # fast XML/locale/password validation (no ISO rebuild)
   |- deploy-os.ps1, preflight-os.ps1, prepare-hardware.ps1, serve-iso.ps1
   |- arm-templates/                # ODIN params (gitignored real) + sanitized example
```

## Current validated workflow

For a fresh demo rebuild, use this sequence:

* Build or obtain the Azure Local 2608 unattended ISO.
* Reimage both nodes in parallel from the jump host; one concurrent HTTP server is sufficient for both iDRACs.
* Run `02-03-validate-nodes.ps1` in validation mode.
* Stage the Dell SBE bundle with `stage-sbe.ps1` when the image does not populate `C:\SBE`.
* Run Stage 4 Register with the existing or auto-created Arc Gateway.
* Run Stage 5 Validate; only then submit Stage 5 Deploy.
* Run Stage 6 after the cluster converges.

SBE staging is a pre-deployment input. Azure Local/LCM applies it during deployment; Azure Update Manager is for post-deployment servicing.

## Quickstart
1. Clone the repo and populate `scripts/powershell/config/lab-config.psd1`.
2. Put the Dell golden ISO under `isos/` (gitignored; never committed).
3. Build the unattended ISO (auto disk-select + network bake):
   ```powershell
   .\make-golden-with-unattend.ps1 -AutoSelectBootDisk -BakeNetworkConfig `
     -GoldenIso ..\..\isos\AzureLocal...A01.en-us.iso `
     -OutputIso ..\..\isos\AzureLocal-auto.iso
   ```
4. Deploy a node (from the jump host):
   ```powershell
   .\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -HttpHost 10.8.230.221 `
     -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
     -ISOFile ..\..\isos\AzureLocal-auto.iso -StartInstallation -NoCertWarn
   ```
5. Continue through Stages 2-6 per `docs/deployment-guide.md`.

## Security
- No credentials, tenant IDs, subscription IDs, or ISOs in the repo.
- Real ARM parameters (`arm-templates/ODIN-parameters.json`) are gitignored.
- The local Administrator password lives in the private runbook only.
