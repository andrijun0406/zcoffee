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
| **"No compatible bootloader available"** (or boots via iDRAC HTML5 native Map CD/DVD but NOT via the script) | **Single-threaded `serve-iso.ps1`** could not satisfy the iDRAC boot-time streaming pattern (many concurrent HTTP Range reads) | Use the current multi-threaded, Range-aware `serve-iso.ps1`. See below. |

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

### "No compatible bootloader" — ISO boots via native Map but not via the script (confirmed, fixed)
Symptom: with Secure Boot **Disabled** and the ISO **mounted** (`racadm remoteimage -s` shows Enabled), the node still fails to boot the Virtual Optical Drive — often reporting `no compatible bootloader available`. The **same ISO, same PC, same Sangfor VPN** boots fine when mapped through the iDRAC HTML5 **Virtual Console → Virtual Media → Map CD/DVD**.

How to tell this apart from the Secure Boot failure:
- Secure Boot failure: `Boot Failed` **immediately**, and `get BIOS.SysSecurity.SecureBoot` returns **Enabled**.
- This failure: Secure Boot is **Disabled**, media is **mounted**, native Map CD/DVD **boots**, but the scripted `racadm remoteimage` path does not.

Root cause: mounting an ISO needs only light reads (headers/directory), so a simple server can mount it. **Booting** is different — UEFI issues sustained, concurrent HTTP **Range** requests. The original single-threaded `HttpListener` loop processed one request at a time, so boot-time range reads queued and timed out, and UEFI saw a truncated/unreadable boot image. The iDRAC HTML5 native map works because it streams over the iDRAC's own console channel, not our HTTP server.

Fix: `serve-iso.ps1` is now **multi-threaded** (runspace pool, up to 24 parallel requests), with correct `206 Partial Content` / `Content-Range` handling, HTTP/1.1 keep-alive, and client-disconnect tolerance. No change to how you run Stage 1 — the orchestrator launches it the same way.

Fallbacks if the scripted boot still fails on a given node:
1. iDRAC HTML5 **Virtual Console → Virtual Media → Map CD/DVD** to the local ISO, then set next boot to Virtual CD/DVD. (Proven to work over the VPN.)
2. Run Stage 1 from a **jump host inside `10.8.230.0/24`** (`-HttpHost 10.8.230.225`) to remove VPN latency from the boot stream entirely.

### VPN throughput tuning (sequential boot + relaxed timeouts)
When booting two nodes over a client VPN, the two iDRACs pulling the boot image **at the same time** can saturate the uplink and cause both boots to fail. Two mitigations are built in:

- **Sequential boot (default for >1 node).** Stage 1 now boots one node, then paces the next so their boot-image reads do not overlap. Control it with:
  - `-NodeBootGapSeconds 0` (default): prompt to press Enter after each node reaches Windows Setup, then boot the next.
  - `-NodeBootGapSeconds 300`: wait a fixed 5 minutes between nodes (hands-off).
  - `-ParallelNodes`: opt back into booting all nodes at once (old behavior).
- **Relaxed HTTP.sys timeouts in `serve-iso.ps1`.** IdleConnection/EntityBody/DrainEntityBody are raised to 10 minutes, HeaderWait to 2 minutes, and `MinSendBytesPerSecond` lowered to 64 so a slow VPN uplink is not dropped mid-stream. The stream chunk is 256 KB (gentler on lossy links). These are best-effort and platform-dependent.

If a single node still cannot boot the ISO over the VPN even sequentially, the bottleneck is the iDRAC's own reverse path to your PC over Sangfor (the native HTML5 map avoids this by streaming through the console channel). In that case the **jump host inside the DC is the durable fix** — it gives the iDRAC a LAN-speed, low-latency read.

Note: the earlier Secure Boot section's "not an HTTP-server problem" statement applies to *that* symptom (immediate Boot Failed with Secure Boot Enabled). This is a distinct, separately-fixed HTTP-server issue.

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
