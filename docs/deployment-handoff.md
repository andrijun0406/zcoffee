# Azure Local Lab (Jakarta 01) — Session Handoff & Resume Brief

Purpose: paste this document as the opening message in a new SalesChat session to resume the Azure Local two-node lab automation project exactly where it left off. It captures the project, current state, the full script inventory, the configuration source of truth, the hard-won root causes, and the next actions.

## How to resume in a new session

Start the new session with: "Continue my Azure Local Jakarta 01 lab automation project. Here is the full handoff brief:" then paste this document. The most useful attachments to re-upload are the current `scripts/powershell/` files, `docs/`, and `config/lab-config.psd1`. The GitHub repo is `andrijun0406/zcoffee` (branch: main is the true path after consolidation).

## Project overview

Goal: build and configure a two-node Azure Local cluster (Storage Spaces Direct, Hyper-V, switchless storage networking) with an automation-first PowerShell + ARM workflow, documented in GitHub, so the environment can be redeployed easily and later grow demo capabilities.

Hardware: two Dell PowerEdge R650 nodes.
- 2 x Intel Xeon Gold 4314 (16C/32T), 8 x 16 GB RAM
- 2 x 800 GB SAS SSD (cache), 6 x 2.4 TB HDD (capacity)
- BOSS-S2 with 2 x ~223 GB M.2 SATA SSD in RAID-1 (OS boot)
- Storage NIC: QLogic FastLinQ QL41262 2x25GbE (PCIe, SLOT 2) — iWARP
- Mgmt/Compute NIC: QLogic QL41232 2x25GbE (integrated rNDC) — NOT the Intel X710 originally on the build sheet; hwinventory confirmed QL41232 on both nodes
- 1GbE LOM: Broadcom BCM5720

Design: 2-node switchless storage over dual 25GbE back-to-back; management/compute on the integrated 25GbE ports via the ToR switch; Local Identity + Azure Key Vault (no Active Directory); dedicated Azure Cloud Witness for quorum.

Supportability caveat: R650 is treated as LAB-ONLY. Dell 2606 release notes list the 15G SBE for AX-650/750/6515/7525, not R650. Do not treat this as a Dell-supported Azure Local configuration without written platform confirmation.

## Identities and network (see private runbook for secrets)

- Tenant ID: 2fab734c-3581-4c94-8c73-8f6dbee0ab86
- Subscription ID: 859c4879-999f-4cd5-a9bb-df171e8d1ad8
- Resource Group: azljkt01rg; Deployment: azljkt01dep; Custom Location: azljkt01loc
- Cluster (no hyphen): azljkt01clu.zcoffee.com
- Key Vault: azljkt01kv; Diagnostic storage: azljkt01diag; Cloud Witness storage: azljkt01wit
- Region: southeastasia; Local DNS zone: zcoffee.com; DNS server: 10.8.230.51
- Subnet 10.8.230.0/24, VLAN 230, Gateway 10.8.230.1
- Infra IP pool: 10.8.230.132 - 10.8.230.137 (reserved — do not use for anything else)
- Storage VLANs 711 / 712; storage auto-IP via Network ATC on 10.71.0.0/16
- Node 1: azljkt01n1 host 10.8.230.232, iDRAC 10.8.230.84, service tag JF7C7J3
- Node 2: azljkt01n2 host 10.8.230.235, iDRAC 10.8.230.86, service tag 1G7C7J3
- Security profile (ODIN): Recommended — WDAC, Credential Guard, Drift Control, SMB signing, BitLocker boot+data all ENABLED; SMB cluster encryption DISABLED (lab choice)

Credentials are NOT stored here. iDRAC currently root / factory default — ROTATE before go-live. Local admin (answer file) is set at ISO-build time. Never commit secrets; `ODIN-parameters.json` is gitignored.

## CURRENT STATE (as of this handoff)

Stage 1 (OS deployment) is essentially solved and proven:
- Node .84 (azljkt01n1): INSTALLED successfully, fully hands-off, via the slipstreamed single-RFS unattended ISO (interactive disk pick was used on .84).
- Node .86 (azljkt01n2): NOT yet installed. It is the test node for the new automatic BOSS disk-selection ISO.
- Firmware: both nodes updated to BIOS 1.12.1 (from 1.4.4). Secure Boot currently DISABLED on both (workaround) — must be re-enabled before Stage 5.
- BOSS VDs were recreated (RAID-1) on both nodes earlier.

Immediate next action: rebuild the unattend ISO (auto disk-select is now default) and run Stage 1 on .86 only to validate automatic disk selection, then confirm both nodes installed.

## THE ROOT CAUSE (the multi-hour boot saga — do not re-litigate)

CONFIRMED: mounting a second iDRAC Remote File Share image (RFS2, used for a separate Autounattend ISO) BLOCKS the golden ISO on RFS1 from booting. With both mounted, only "Virtual Network File 2" enumerated in UEFI; the golden ISO never presented. Detaching RFS2 made the golden ISO boot immediately.

What was RULED OUT along the way (do not chase these again):
- VPN reverse path: ruled out — jump host on the LAN still failed the same way while RFS2 was mounted.
- Secure Boot / old BIOS cert store: ruled out — BIOS 1.4.4 -> 1.12.1 did not fix it.
- Single-threaded HTTP server: improved but was not the cause.
- Firewall/RAC0718: that was a separate earlier issue (blocked inbound TCP 8080 caused a half-open RFS session -> RAC0718 "service busy"); fixed by allowing 8080 and it is now a firewall preflight check.

The SOLUTION adopted: single-RFS mount only. Deliver the answer file by SLIPSTREAMING Autounattend.xml into the golden ISO (one mount, fully unattended) using oscdimg. The RFS2 path was removed from the automation entirely.

Native iDRAC HTML5 "Map CD/DVD" always booted because it presents as console "Virtual Optical Drive"; scripted RFS presents as "Virtual Network File" — a different boot device.

## Script inventory (scripts/powershell/)

Orchestration:
- bootstrap-cluster.ps1 — dispatcher; selects a stage, forwards only provided params (rest fall back to config). Key params: -Stage, -HttpHost, -RACADMPath, -ISOFile, -StartInstallation, -NoCertWarn, -OnlyNode, -ParallelNodes, -NodeBootGapSeconds, hardware-prep switches.
- ui-common.ps1 — shared console dashboard (steps, progress, warn/err, elapsed, per-stage log under logs/), optional -UseGui Windows Forms window; also hosts Import-LabConfig and Resolve-Setting.

Stages (six-stage sequence, matches Dell switchless + Microsoft flow):
- 01-deploy-os.ps1 — ACTIVE. Preflight, native PowerShell ISO server, per-node RACADM mount + one-time boot; sequential boot by default for >1 node; -OnlyNode filter; firewall preflight.
- 02-configure-network.ps1 — placeholder (Network ATC: Mgmt/Compute intent on QL41232 rNDC ports, Storage intent on QL41262 SLOT 2 ports, VLANs 711/712, iWARP, storage auto-IP). Validation-only; -Apply gated.
- 03-prepare-node.ps1 — placeholder (hostname, DNS, dedicated non-builtin local admin, security baseline, firmware/SBE readiness).
- 04-register-arc.ps1 — placeholder (Azure context, resource providers, Arc registration, SBE).
- 05-deploy-azure-local.ps1 — ARM deployment; validation by default, requires -EnableDeployment + typed DEPLOY confirmation. Uses arm-templates.
- 06-validate-cluster.ps1 — cluster object, node state, quorum, S2D health checks.

Workers / helpers:
- deploy-os.ps1 — low-level RACADM worker. Single-RFS mount ONLY (RFS2 attach removed; still DETACHES stale RFS2 before mounting RFS1). -DetachOnly mode; detach-wait/poll + connect retry (handles async remoteimage -d and RAC0718); password-masked command echo; -StartInstallation gates boot + power-cycle; -UseUefiBootOrder available for flaky one-time-boot firmware.
- preflight-os.ps1 — non-destructive checks: ISO/hash, HttpHost assigned to this PC, RACADM present, iDRAC HTTPS reachable, inbound TCP 8080 firewall rule; -SkipIso mode for hardware-only runs.
- prepare-hardware.ps1 — firmware/BIOS/iDRAC updates + BOSS VD recreate + Secure Boot toggle. Switches: -FirmwareCheckOnly (verifycatalog, non-destructive), -UpdateFirmware (full catalog, -a TRUE --reboot), -UpdateBios (single BIOS DUP), -UpdateIdrac (single iDRAC DUP), -RecreateBossVd (destructive, no prompt — flag is the confirmation; type-aware disk parser handles BOSS Disk.Direct on AHCI), -DisableSecureBoot / -EnableSecureBoot. Firmware check uses `-f Catalog.xml.gz -e <repo> --verifycatalog`.
- serve-iso.ps1 — native PowerShell HttpListener server (no Python). Multi-threaded (runspace pool), HTTP Range/206, keep-alive, disconnect-tolerant, VPN-tuned HTTP.sys timeouts. Binds http://+:8080/.
- make-golden-with-unattend.ps1 — CURRENT unattended-ISO builder. Slipstreams Autounattend.xml into the golden ISO via oscdimg (BIOS+UEFI boot, UDF, efisys_noprompt.bin = no "press any key"). AUTOMATIC BOSS disk selection is the DEFAULT (WinPE RunSynchronous diskpart, matches BOSS by controller identity regex (?i)boss, halts if ambiguous, logs to Windows\Temp\bootdisk-select.log). Switches: -InteractiveDiskSelect (opt out), -BootDiskModelMatch, -BootDiskMaxSizeGB, -OscdimgPath, -GoldenIso, -OutputIso.
- make-autounattend-iso.ps1 — DEPRECATED (was the RFS2 second-ISO generator; superseded by slipstream).

Config / templates:
- config/lab-config.psd1 — SINGLE SOURCE OF TRUTH (DNS, VLANs, gateway, names, node host+iDRAC IPs, service tags, HTTP port, firmware catalog URL, adapters). Params override it at runtime. Compare against docs/odin-config-report.md.
- arm-templates/azure-local.parameters.example.json — sanitized, committable (placeholders for tenant/subscription/RP object id).
- arm-templates/ODIN-parameters.json — real values, GITIGNORED (local only).

Docs (docs/):
- deployment-guide.md, lab-architecture.md, troubleshooting.md, odin-config-report.md, deployment-journey.md (chronological decision log).

## Key environment facts and gotchas

- Dev PC reaches the DC only via Sangfor EasyConnect VPN (client SSL VPN). The PC's VPN IP varies per session (2.2.2.x). Serving the ISO from the PC works for MOUNT but the iDRAC reverse path is fragile — jump host is preferred.
- Jump host: 10.8.230.221 (Server Core, name WACGW-AZURE), inside the DC LAN. RACADM installed there (v11.4.0.0). Run Stage 1 there with -HttpHost 10.8.230.221.
- Server Core gotchas: install RACADM with absolute path and /qn, and DROP ADDLOCAL=RACADM (invalid feature name -> error 2711/1603). PowerShell 5.1 needs -UseBasicParsing (no IE engine) — already applied in scripts. Use oscdimg, not IMAPI2 (IMAPI2FS COM not registered on Core; also unreliable for large Windows ISOs -> 0xC0AAB132).
- Getting files to the jump host: `\\tsclient\` RDP redirection is too slow/unstable for 8 GB (ERROR 995); C$ push fails with ERROR 1326 unless LocalAccountTokenFilterPolicy=1. BEST: build the unattend ISO ON the jump host (copy only the ~2 MB oscdimg.exe), since the 8 GB golden ISO is already there.
- ISOs are gitignored (isos/, *.iso, *unattend*.iso) — sync scripts via git, move ISOs separately/build locally.
- Inbound TCP 8080 firewall rule required on whichever host serves the ISO.
- Firmware "Available Version" from dl.dell.com is latest, not support-matrix-pinned — for compliance use a Dell Repository Manager catalog. SBE applies the validated baseline during Stage 5.

## Proven Stage 1 command (single node, jump host)

Rebuild ISO (auto disk-select baked in):
```
.\make-golden-with-unattend.ps1 -OscdimgPath C:\Tools\oscdimg\oscdimg.exe -GoldenIso ..\..\isos\AzureLocal24H2.26100.32230.LCM.12.2604.1.3008_DellSBE.5.0.2606.1510_15G-Intel_A01.en-us.iso -OutputIso ..\..\isos\AzureLocal-unattend.iso
```
Deploy .86 only:
```
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode 10.8.230.86 -HttpHost 10.8.230.221 -RACADMPath "C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe" -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn
```

## Next steps (roadmap)

1. Rebuild the unattend ISO on the jump host and run Stage 1 on .86 to validate AUTOMATIC disk selection (watch console: no disk prompt = success; if it stops, guard tripped — check X:\Windows\Temp\bootdisk-select.log via Shift+F10). It cannot wipe an S2D disk.
2. Confirm both nodes installed and reachable; sign in with the answer-file admin password; delete C:\Windows\Panther\unattend.xml on each.
3. Re-enable Secure Boot on both nodes (prepare-hardware.ps1 -EnableSecureBoot) — required for the cluster. Consider whether to keep BIOS at 1.12.1 or align to a matrix-pinned version.
4. Rotate iDRAC and local admin passwords; stop using inline -p; scrub PowerShell history.
5. Implement Stage 2 (02-configure-network.ps1) for real using config adapters (QL41232 rNDC = Mgmt/Compute; QL41262 SLOT 2 = Storage), VLANs 711/712, iWARP, storage auto-IP; validate-first with -Apply gate.
6. Stage 3 node prep, Stage 4 Arc registration + SBE, Stage 5 ARM deploy (validation first, then -EnableDeployment), Stage 6 cluster validation.
7. Keep lab-config.psd1 reconciled with the ODIN config report before any deployment (DNS cannot change post-deployment).

## Open decisions / reminders

- Cluster name standard: azljkt01clu (no hyphen) — settled.
- DNS: 10.8.230.51 — settled (ODIN updated to match).
- SMB cluster encryption: DISABLED (lab) — settled.
- Automatic disk selection: DEFAULT (opt out with -InteractiveDiskSelect) — pending validation on .86.
- branches/ folder cleanup: try-cifs (dead end) and try-jumphost helpers — decide whether to keep copy-to-jumphost.ps1 and drop the CIFS experiments.
- Verify hciResourceProviderObjectID in the tenant before Stage 5.


## Progress update (latest)

- Stage 1: hands-off confirmed (WMIC DELLBOSS VD auto-select + MAC-based network bake). Nodes come
  up reachable at .232/.235 with no iDRAC console.
- Stage 2: PASS (mgmt + storage 25GbE up).
- Stage 3: PASS both nodes (Secure Boot on, SBE staged, egress 4/4, Env Checker green).
- Stage 4: Validate PASS; Register pending. Service-principal auth available (`-ServicePrincipalId`
  + `-ServicePrincipalSecret`/`-ServicePrincipalCertThumbprint`).
- Stage 5: pending — needs the Microsoft/Dell `azuredeploy.json` ARM template in `arm-templates/`
  and both nodes Arc-Connected.
- Next: build zero-touch orchestrator (one SP login, `Wait-NodeReady` across reboots, gates on
  Arc-Connected + Stage-3-green, `-AutoApprove` for Register + Deploy).
