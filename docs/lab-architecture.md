# Lab Architecture

## Supportability note (read first)
The current Dell Azure Local **2606** support matrix and SBE release notes list 15G AX platforms (AX-650/AX-750/AX-6515/AX-7525) and 16G/17G PowerEdge platforms — **not the PowerEdge R650**. This lab is therefore **lab-only / experimental**. Do not represent it as a Dell-validated Azure Local configuration unless Dell confirms the exact R650 + QLogic FastLinQ 41262 + firmware + OS + SBE combination in writing.

## Hardware (per node)
- Dell PowerEdge R650
- 2 x Intel Xeon Gold 4314 (16C/32T)
- 8 x 16GB RAM (128 GB)
- 2 x 800GB SSD SAS (cache)
- 6 x 2.4TB HDD (capacity)
- rNDC: Intel X710 2x10GbE + 2 x 1GbE
- PCIe: QLogic FastLinQ 41262 2x10/25GbE

## Network topology (switchless storage)
- **Management/Compute**: two Intel X710 10GbE ports to the ToR switch, VLAN 230, `10.8.230.0/24`.
- **Storage**: QLogic FastLinQ 41262, two 25GbE links connected **back-to-back** between nodes.
  - StorageNetwork1: Port 3, VLAN 711
  - StorageNetwork2: Port 4, VLAN 712
  - RDMA enabled; the FastLinQ 41262 is validated with **iWARP** (not RoCE).
  - No default gateway on storage; storage IPs assigned automatically by Network ATC.
- Switchless storage covers only east-west storage traffic. Management, compute, DNS, Arc, and VM traffic still use the switched 10GbE network.

### Port configuration (from ODIN config report)
| Port | Speed | RDMA | Role |
|------|-------|------|------|
| Port 1 | 10GbE | No | Management + Compute |
| Port 2 | 10GbE | No | Management + Compute |
| Port 3 | 25GbE | Yes | StorageNetwork1 (VLAN 711) |
| Port 4 | 25GbE | Yes | StorageNetwork2 (VLAN 712) |

## Identity & security
- Local Identity + Azure Key Vault (AD-less).
- Local DNS zone: `zcoffee.com`.
- DNS server (forwarder): **`10.8.230.51`**, defined in `lab-config.psd1`. Keep the ODIN config report aligned with this value (DNS cannot change post-deployment).
- Security baseline (Recommended): WDAC, Credential Guard, drift control, SMB signing, SMB cluster encryption, BitLocker on boot and data volumes.

## Infrastructure network
| Setting | Value |
|---------|-------|
| IP assignment | Static |
| VLAN ID | 230 |
| Infra CIDR | `10.8.230.0/24` |
| Infra IP pool | `10.8.230.242 - 10.8.230.247` (>= 6 contiguous IPs) |
| Default gateway | `10.8.230.1` |
| Storage subnets | Network ATC auto-IP (`10.71.0.0/16`) |

Do not overlap `10.96.0.0/12` or `10.244.0.0/16` (reserved for AKS Arc / Arc Resource Bridge).

## Node and iDRAC addressing
| Node | Host name | Host IP | iDRAC IP | Service Tag |
|------|-----------|---------|----------|-------------|
| 1 | azljkt01n1 | `10.8.230.222` | `10.8.230.84` | JF7C7J3 |
| 2 | azljkt01n2 | `10.8.230.232` | `10.8.230.86` | 1G7C7J3 |

## DNS & naming convention

Pattern: `azl<location><instance><role>` — lowercase, **no hyphens** for DNS and Azure resource names.

- `azl` → Azure Local environment
- `<location>` → site (e.g. `jkt` Jakarta)
- `<instance>` → `01`, `02`, `lab`, `prod`
- `<role>` → `clu`, `n1`, `n2`, `rg`, `dep`, `loc`, `kv`, `diag`, `wit`

### Jakarta Cluster 1 (Lab)
| Object | Name |
|--------|------|
| Cluster | `azljkt01clu.zcoffee.com` |
| Node 1 | `azljkt01n1.zcoffee.com` |
| Node 2 | `azljkt01n2.zcoffee.com` |
| Resource Group | `azljkt01rg` |
| Deployment Name | `azljkt01dep` |
| Custom Location | `azljkt01loc` |
| Key Vault | `azljkt01kv` |
| Diagnostic Storage | `azljkt01diag` |
| Cloud Witness Storage | `azljkt01wit` |

> Naming: resolved to no-hyphen `azljkt01clu`. Scripts (`bootstrap-cluster.ps1`, `06-validate-cluster.ps1`) and the ARM parameter example now default to `azljkt01clu`. Ensure DNS A records match.

## Azure scope (from ODIN config report)
- Scenario: connected · Azure Commercial · Region: Southeast Asia
- Scale: Standard · Nodes: 2 · Cloud Witness: Cloud
- Arc Gateway: Enabled (recommended) · Proxy: disabled · Private endpoints: disabled
- SDN features: lnet, nsg (Arc-managed)

## Best practice
- Keep tenant IDs, subscription IDs, and secrets in the private runbook, not in GitHub.
- Start larger-capacity drives first; nodes must remain homogeneous.
- Switchless storage does not support add-node scale-out; choose switched/scalable storage now if growth is expected.
