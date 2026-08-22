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
- Azure CLI for Stage 5.
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

# 2. Deploy with ONE RFS mount (no RFS2). Fully unattended except the disk-selection screen.
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost <server-ip> `
  -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn
```

`make-golden-with-unattend.ps1` repacks the ISO with **oscdimg**: it mounts the golden ISO, robocopies the tree to a staging folder, drops `Autounattend.xml` at the root, and rebuilds with UDF (the install image inside can exceed the 4 GB ISO9660 limit) plus the BIOS+UEFI El Torito boot catalog (`efisys_noprompt.bin`, which also removes the "Press any key to boot" prompt). IMAPI2 was tried first but fails on large dual-boot Windows media (error `0xC0AAB132` in `CreateResultImage`) and is not registered on Server Core — oscdimg is the reliable, Microsoft-supported path. Building needs free disk ~2x the ISO size (staging + output). Disk selection stays interactive to protect the S2D data disks; select the BOSS RAID-1 `OS` volume. Validate the first output by booting one node before relying on it for both.

> [!NOTE]
> The `01-deploy-os.ps1` worker no longer mounts a second RFS image at all; it actively clears any stale RFS2 before mounting RFS1. The older `make-autounattend-iso.ps1` (separate RFS2 ISO) is deprecated — use `make-golden-with-unattend.ps1` instead.

## Stage 2 — Host networking (`02-configure-network.ps1`)

Defines management VLAN 230 and storage VLANs 711/712. Currently a guarded placeholder; `-Apply` intentionally stops until exact OS adapter names and Network ATC intents are confirmed.

- Management/Compute intent on Integrated NIC1 Port 1-1 and Port 2-1 (QLogic QL41232 2x25GbE rNDC).
- Storage intent on SLOT 2 Port 1 and Port 2 (QLogic QL41262 2x25GbE); RDMA/iWARP; storage auto-IP (`10.71.0.0/16`).
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
