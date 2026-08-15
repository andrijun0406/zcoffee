# Deployment Guide

This guide maps the six-stage automation to the Dell AX System for Azure Local (switchless networking) and Microsoft Azure Local deployment flow. Every stage uses the shared `ui-common.ps1` dashboard (colored steps, progress, warnings/errors, elapsed time, per-stage log under `logs/`, optional `-UseGui` window).

## Table of contents

- [Supportability and scope](#supportability-and-scope)
- [Pre-deployment](#pre-deployment)
- [Configuration source of truth](#configuration-source-of-truth)
- [Tooling prerequisites](#tooling-prerequisites)
- [Stage 1 — OS deployment](#stage-1--os-deployment-01-deploy-osps1)
- [Stage 2 — Host networking](#stage-2--host-networking-02-configure-networkps1)
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
- Verify cabling: 25GbE back-to-back for storage (SLOT 2 Port 1/2), 10GbE for management/compute (Integrated NIC1 Port 1-1/2-1).
- Confirm VLAN/IP layout:
    - VLAN 230 → Management/Compute (`10.8.230.0/24`)
    - VLAN 711 → StorageNetwork1 (SLOT 2 Port 1)
    - VLAN 712 → StorageNetwork2 (SLOT 2 Port 2)
- Firmware/software compliance: validate against the Dell Support Matrix and record BIOS/NIC/driver/SBE versions in the private runbook. Update all nodes before OS deployment.

## Configuration source of truth

> [!IMPORTANT]
> All values (DNS, VLANs, gateway, cluster/resource names, node and iDRAC IPs, HTTP port, local admin) are defined once in `lab-config.psd1` and loaded by every stage. Passing a parameter overrides the config for that run. Compare `lab-config.psd1` with [`odin-config-report.md`](./odin-config-report.md) before deployment.

## Tooling prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+, run as Administrator.
- Dell RACADM on PATH or via `-RACADMPath`.
- Python 3.x on PATH (`py`, `python`, or `python3`) — used only to serve the Golden Image ISO over HTTP so RACADM can mount it to each iDRAC. Verify with `python --version` or `py --version`.
- Azure CLI for Stage 5.
- Keep the Golden Image ISO under `isos/` (gitignored). Never commit ISOs.

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
> - Prepare/clean the BOSS boot virtual disk in iDRAC before installing.
> - Use `-ExpectedISOHash <sha256>` to enforce image integrity.

## Stage 2 — Host networking (`02-configure-network.ps1`)

Defines management VLAN 230 and storage VLANs 711/712. Currently a guarded placeholder; `-Apply` intentionally stops until exact OS adapter names and Network ATC intents are confirmed.

- Management/Compute intent on Integrated NIC1 Port 1-1 and Port 2-1 (10GbE).
- Storage intent on SLOT 2 Port 1 and Port 2 (25GbE); RDMA/iWARP; storage auto-IP (`10.71.0.0/16`).
- Let Network ATC own host networking; avoid manual SET teams or storage vNICs.

## Stage 3 — Node preparation (`03-prepare-node.ps1`)

Guarded placeholder for hostname, DNS A records, the dedicated non-built-in local admin, security baseline, firmware/SBE readiness, and environment validation.

- Static management IPs: `azljkt01n1` → `10.8.230.71`, `azljkt01n2` → `10.8.230.72`.
- DNS forwarder: **`10.8.230.51`** (from `lab-config.psd1`).
- Security baseline: BitLocker (boot + data), Credential Guard, WDAC, SMB signing, drift control.

> [!CAUTION]
> Keep the ODIN report aligned with `lab-config.psd1`. DNS server IPs cannot change after deployment.

## Stage 4 — Azure Arc registration (`04-register-arc.ps1`)

Validate-first placeholder for Azure context, resource providers, RBAC, Arc registration, post-reboot health, and Dell SBE applicability. Use the release-matched Arc initialization procedure when implemented.

## Stage 5 — Azure Local deployment (`05-deploy-azure-local.ps1`)

ARM validation by default. Deployment requires `-EnableDeployment` and a typed `DEPLOY` confirmation after `what-if`.

```powershell
.\bootstrap-cluster.ps1 -Stage 05-deploy-azure-local `
  -SubscriptionId <sub-id> -TenantId <tenant-id> `
  -TemplateFile ..\arm-templates\azuredeploy.json `
  -ParameterFile ..\arm-templates\azure-local.parameters.json
```

> [!TIP]
> Two-node deployment requires a dedicated Cloud Witness storage account; use one Key Vault per cluster. Deploy once via the portal first, then standardize the ARM template.

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
