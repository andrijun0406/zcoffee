# zcoffee: Azure Local 2-Node Lab Deployment (Jakarta 01)

Automation and documentation to deploy a **2-node Azure Local** cluster with Storage Spaces Direct (S2D), Hyper-V, and **switchless storage networking** on Dell PowerEdge R650 nodes.

> Support note: The current Dell Azure Local 2606 support matrix lists 15G AX platforms (AX-650/AX-750/AX-6515/AX-7525) and 16G/17G PowerEdge platforms, not the R650. Treat this lab as **lab-only / experimental** unless Dell confirms the exact R650 + NIC + firmware + OS + SBE combination. See `docs/lab-architecture.md`.

## Repository layout

```
zcoffee/
├── README.md
├── docs/
│   ├── lab-architecture.md
│   ├── deployment-guide.md
│   ├── deployment-journey.md    # chronological problem-and-fix decision log (Stage 1)
│   ├── troubleshooting.md
│   └── odin-config-report.md
├── scripts/
│   ├── powershell/
│   │   ├── config/
│   │   │   └── lab-config.psd1        # single source of truth for lab values
│   │   ├── logs/                      # per-stage run logs (gitignored, auto-created)
│   │   ├── bootstrap-cluster.ps1      # stage dispatcher (+ -UseGui)
│   │   ├── ui-common.ps1              # shared dashboard / logging / GUI + config loader
│   │   ├── preflight-os.ps1           # non-destructive OS prerequisite checks
│   │   ├── deploy-os.ps1              # RACADM worker (single-RFS mount, optional boot)
│   │   ├── prepare-hardware.ps1       # firmware check/update + BOSS boot VD recreate
│   │   ├── make-golden-with-unattend.ps1 # slipstreams Autounattend.xml INTO the golden ISO via oscdimg (single RFS)
│   │   ├── make-autounattend-iso.ps1  # DEPRECATED (separate RFS2 ISO; breaks boot on this firmware)
│   │   ├── make-unattend-xml-only.ps1  # emits ONLY Autounattend.xml for fast live validation (setup.exe /unattend:)
│   │   ├── serve-iso.ps1              # native PowerShell ISO HTTP server (no Python)
│   │   ├── 01-deploy-os.ps1
│   │   ├── 02-configure-network.ps1
│   │   ├── 03-prepare-node.ps1
│   │   ├── 04-register-arc.ps1
│   │   ├── 05-deploy-azure-local.ps1
│   │   └── 06-validate-cluster.ps1
│   └── arm-templates/
│       └── azure-local.parameters.example.json
└── isos/                              # golden image + generated unattended ISO (gitignored)
```

## Prerequisites
- 2 x Dell PowerEdge R650 (see `docs/lab-architecture.md`).
- Management PC with Windows PowerShell 5.1+ or PowerShell 7+, run as Administrator.
- Dell RACADM (iDRAC Tools) on PATH or provided via `-RACADMPath`.
- No Python needed — the ISO is served by a native PowerShell HTTP server (`serve-iso.ps1`).
- Dell-provided Azure Local Golden Image ISO under `isos/` (not committed).
- Azure CLI for the Azure Local deployment stage.
- Network: VLAN 230 (`10.8.230.0/24`) management/compute; VLANs 711/712 for switchless storage.
- Sangfor VPN access to the datacenter.
- VS Code with PowerShell + ARM Tools extensions.
- Azure subscription and tenant (kept in the private runbook, never in this repo).

## Configuration (single source of truth)

All lab values live in `scripts/powershell/config/lab-config.psd1` (DNS, VLANs, gateway, cluster/resource names, node host and iDRAC IPs, HTTP port, local admin, subscription/tenant placeholders). Every stage loads it via `Import-LabConfig`, which resolves the `config/` folder relative to the scripts.

Precedence: an explicitly passed parameter overrides the config; otherwise the config value is used; otherwise a built-in fallback applies.

Keep `config/lab-config.psd1` aligned with the ODIN config report (`docs/odin-config-report.md`). Compare the two before every deployment, since values such as DNS server IPs cannot change after deployment. Do not put secrets in `lab-config.psd1`.

## Six-stage workflow

| Stage | Script | Purpose |
|-------|--------|---------|
| 1 | `01-deploy-os.ps1` | Serve Golden Image ISO, preflight, mount via RACADM, optionally boot each node. |
| 2 | `02-configure-network.ps1` | Host networking (mgmt VLAN 230; storage VLANs 711/712). Placeholder until validated. |
| 3 | `03-prepare-node.ps1` | Hostname, DNS records, local identity, security baseline, readiness. Placeholder. |
| 4 | `04-register-arc.ps1` | Azure Arc registration and Dell SBE readiness. Placeholder / validate-first. |
| 5 | `05-deploy-azure-local.ps1` | ARM validation by default; deployment requires `-EnableDeployment`. |
| 6 | `06-validate-cluster.ps1` | Post-deployment cluster, quorum, and S2D health checks. |

All stages share `ui-common.ps1`, which provides a colored console dashboard, numbered step progress, `[OK]/[INFO]/[WARN]/[ERR]` lines, elapsed time, a per-stage log under `logs/`, and an optional Windows Forms window via `-UseGui`.

## Quickstart

```powershell
# 1. Clone
git clone https://github.com/andrijun0406/zcoffee.git
cd zcoffee/scripts/powershell

# 2. Place the Dell Golden Image ISO under ..\..\isos\  (gitignored)

# 3. Stage 1 - mount ISO only (no reboot), console dashboard
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.225 -NoCertWarn

# 4. Stage 1 - mount + one-time virtual DVD boot + power-cycle, with GUI window
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.225 `
  -StartInstallation -NoCertWarn -UseGui

# 5. Later stages (validation-first)
.\bootstrap-cluster.ps1 -Stage 05-deploy-azure-local `
  -SubscriptionId <sub-id> `
  -TemplateFile ..\arm-templates\azuredeploy.json `
  -ParameterFile ..\arm-templates\azure-local.parameters.json
```

## Conventions
- No credentials, tenant IDs, subscription IDs, or secrets in this repo. Keep them in the private runbook.
- `isos/` and `logs/` are gitignored.
- DNS forwarder is defined once in `lab-config.psd1` as `10.8.230.51`. Update the ODIN report to match. DNS server IPs cannot change after deployment, so confirm before deploying.
- Azure resource and DNS names are lowercase, no hyphens (for example `azljkt01clu`).

## Deployment notes

The Stage 1 OS bring-up went through several dead ends before landing on the current
design (single RFS mount + answer file slipstreamed into the golden ISO + automatic BOSS
disk selection). The full problem-and-fix journey — including what ruled out Secure Boot,
BIOS version, the VPN, and the HTTP server — is in
[`docs/deployment-journey.md`](docs/deployment-journey.md). Symptom-to-fix lookups are in
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## Sources
- Dell AX System for Azure Local Deployment and Operations Guide with Switchless Networking (Dell Info Hub).
- Azure Local deployment introduction and local identity with Azure Key Vault (Microsoft Learn).
- Dell Azure Local Support Matrix / SBE release notes (Dell 2606).
