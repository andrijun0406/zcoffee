# Troubleshooting

Each stage writes a timestamped log to `logs/<stage>-<yyyyMMdd-HHmmss>.log` and shows `[OK]/[INFO]/[WARN]/[ERR]` lines. Start troubleshooting from the failing step reported by the dashboard.

## Stage 1 — OS deployment
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "ISO server not reachable" | Bound to loopback/wildcard, or firewall | Pass a reachable `-HttpHost` (e.g. `10.8.230.225`); allow TCP 8080 to both iDRACs |
| RACADM "not found" | RACADM not on PATH | Install Dell iDRAC Tools or pass `-RACADMPath` |
| iDRAC connect fails | Wrong iDRAC IP/creds or HTTPS blocked | Verify iDRAC `10.8.230.84` / `10.8.230.86`, port 443, credentials |
| remoteimage fails | iDRAC can't reach the ISO URL | Confirm both iDRACs reach `http://<HttpHost>:8080/...` |
| Node won't boot installer | Boot device/BOSS not ready | Use `-StartInstallation`; prepare/clean the BOSS virtual disk in iDRAC |
| ISO hash mismatch | Wrong or corrupt ISO | Re-download the Dell Golden Image; verify `-ExpectedISOHash` |

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
