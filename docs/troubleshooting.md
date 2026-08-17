# Troubleshooting

Each stage writes a timestamped log to `logs/<stage>-<yyyyMMdd-HHmmss>.log` and shows `[OK]/[INFO]/[WARN]/[ERR]` lines. Start troubleshooting from the failing step reported by the dashboard.

## Stage 1 — OS deployment
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "ISO server not reachable" | Bound to loopback/wildcard, or firewall | Pass a reachable `-HttpHost` (e.g. `10.8.230.225`); allow TCP 8080 to both iDRACs |
| RACADM "not found" | RACADM not on PATH | Install Dell iDRAC Tools or pass `-RACADMPath` |
| iDRAC connect fails | Wrong iDRAC IP/creds or HTTPS blocked | Verify iDRAC `10.8.230.84` / `10.8.230.86`, port 443, credentials |
| remoteimage fails | iDRAC can't reach the ISO URL | Confirm both iDRACs reach `http://<HttpHost>:8080/...` |
| Node won't boot installer | Boot device/BOSS not ready | Use `-StartInstallation`; recreate the BOSS VD with `-RecreateBossVd` |
| **"Boot Failed: Virtual Optical Drive"** even from manual F11 | **Secure Boot enabled on old BIOS** — the cert store rejects the newly-signed Golden Image bootloader | Disable Secure Boot (`-DisableSecureBoot`), install, then update BIOS and re-enable (`-EnableSecureBoot`). See below. |
| Node boots to PXE instead of the ISO | One-time boot override unreliable on old BIOS | Update BIOS; or press F11 → One-shot UEFI Boot Menu → Virtual Optical Drive |
| BOSS "fewer than 2 physical disks" | (fixed) parser now reads `Disk.Direct` AHCI disks | Ensure you're on the current `prepare-hardware.ps1` |
| Setup asks for a "media driver" mid-install | ISO was detached while installing | Never run a second (mount-only) bootstrap during an install — it detaches media on all targeted nodes. Re-run `-OnlyNode <n> -StartInstallation` |
| ISO hash mismatch | Wrong or corrupt ISO | Re-download the Dell Golden Image; verify `-ExpectedISOHash` |

### Secure Boot boot failure (known issue, confirmed on this lab)
Symptom: the Golden Image will not boot from the Virtual Optical Drive even when selected manually via F11; the node reports `Boot Failed: Virtual Optical Drive` almost immediately.

Root cause: on very old BIOS (e.g. R650 BIOS **1.4.4**), the UEFI Secure Boot certificate store predates the Azure Local 24H2 Golden Image bootloader signature, so Secure Boot rejects it. This is **not** a VPN, HTTP-server, or media problem — the ISO mounts and streams fine over the Sangfor VPN.

Confirm and fix:
```powershell
racadm -r <iDRAC> -u root -p <pw> --nocertwarn get BIOS.SysSecurity.SecureBoot   # Enabled?
racadm -r <iDRAC> -u root -p <pw> --nocertwarn get BIOS.BiosBootSettings.BootMode # keep Uefi
```
Automated path (per node, commits a BIOS job + reboot):
```powershell
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode <iDRAC-or-name> -DisableSecureBoot -NoCertWarn
```
Then run the install. After the OS is on and BIOS is updated (1.4.4 → 1.21.1), re-enable Secure Boot (required for the validated cluster):
```powershell
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode <iDRAC-or-name> -EnableSecureBoot -NoCertWarn
```
Keep `BootMode = Uefi` throughout — never switch to BIOS/Legacy. Only one bootstrap window at a time.

## Stage 2 — Host networking
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| SMB falls back to TCP | RDMA/iWARP not enabled | Enable RDMA; set FastLinQ 41262 to iWARP; check `Get-SmbMultichannelConnection` |
| Intents drift/asymmetry | Adapter name mismatch or manual vNICs | Use identical adapter names; let Network ATC own host networking |
| Storage links not 25GbE | Cabling/optic mismatch | Verify Port 3↔Port 3, Port 4↔Port 4 at 25GbE |

## Stage 3 — Node preparation
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Name resolution fails | Missing DNS A records | Create host/cluster A records on `10.8.230.51` |
| Local identity errors | Built-in admin used | Create a dedicated non-built-in local admin, identical on both nodes |

## Stage 4 — Azure Arc
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Providers not registered | Missing resource providers | Register required providers; recheck registrationState |
| RBAC/registration fails | Wrong object ID, scope, or tenant | Inspect object IDs (not display names); confirm role assignments |
| Outbound blocked | Proxy/SSL inspection or endpoint gaps | Allow required endpoints; disable SSL inspection; validate Arc Gateway coverage |

## Stage 5 — Azure Local deployment
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Validation passes, deploy fails | Wrong adapter names / storage list / IP pool | Match exact OS adapter names; verify infra pool `10.8.230.132-137` |
| Quorum unstable | Witness unreachable or shared | Use a dedicated Cloud Witness account; test outbound HTTPS from both nodes |
| Deploy blocked by default | `-EnableDeployment` not set | Re-run with `-EnableDeployment` after `what-if` review |

## Stage 6 — Cluster validation
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Cmdlets missing | Failover Clustering tools absent | Install RSAT/Failover Clustering on the management host |
| Node mismatch / not Up | Node offline or wrong names | Verify node names and states before rechecking storage |

## General
- Reference the Dell Support Matrix for firmware/driver/BIOS/SBE versions.
- SBE update failing: do not force a package meant for another platform; obtain a matrix-supported bundle.
- Collect logs from `logs/` and the ODIN config report before escalating.
- Document lab-specific quirks and credentials in the private runbook.
