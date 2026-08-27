# Lab Architecture (Jakarta 01)

## Hardware (2 x Dell PowerEdge R650)
- 2 x Intel Xeon Gold 4314 (16C/32T), 8 x 16GB DDR4-2667.
- Boot: **Dell BOSS-S2**, 2 x M.2 in **RAID-1** (~223 GB). Enumerates in WinPE as model
  **`DELLBOSS VD`** (used for automatic boot-disk selection).
- Cache: 2 x 800GB SAS SSD. Capacity: 6 x 2.4TB HDD (Storage Spaces Direct).
- **rNDC: QLogic QL41232 2x25GbE** — Management/Compute.
  (The original build sheet listed Intel X710 2x10GbE; `hwinventory` on both nodes proved it is the
  QLogic QL41232. Ports negotiate at **10GbE** on the current ToR switch.)
- **PCIe SLOT 2: QLogic FastLinQ QL41262 2x25GbE** — Storage (`SLOT 2 Port 1/2`), iWARP.
- Broadcom BCM5720 1GbE LOM (unused for cluster traffic).

## OS-reported adapter names (exact — used by scripts and Stage 5 ARM)
- Management/Compute: `Integrated NIC 1 Port 1-1`, `Integrated NIC 1 Port 2-1`
- Storage: `SLOT 2 Port 1`, `SLOT 2 Port 2`

## Network
- **Switchless storage:** 25GbE back-to-back between the two nodes (SLOT 2 ports).
  - VLAN 711 -> StorageNetwork1 (SLOT 2 Port 1); VLAN 712 -> StorageNetwork2 (SLOT 2 Port 2)
  - Storage auto-IP via Network ATC (`10.71.0.0/16`), created by Stage 5.
- **Management/Compute:** QL41232 rNDC to the ToR. **VLAN 230 is tagged** (trunk, not native) —
  the host tags it via the adapter `VLAN ID` advanced property.
- Subnet `10.8.230.0/24`, gateway `10.8.230.1`, DNS `10.8.230.51`.
- Infrastructure IP pool `10.8.230.132 - 10.8.230.137` (excludes node + iDRAC IPs).

## Nodes
| Node | Name | Service Tag | iDRAC | Host IP | Mgmt MAC |
|------|------|-------------|-------|---------|----------|
| 1 | azljkt01n1 | JF7C7J3 | 10.8.230.84 | 10.8.230.232 | 34:80:0D:2E:7B:B0 |
| 2 | azljkt01n2 | 1G7C7J3 | 10.8.230.86 | 10.8.230.235 | 34:80:0D:2E:8B:88 |

> Node host IPs are `.232/.235` (the originally planned `.71/.72` were already in use; the DC admin
> reassigned them). Service tag -> node identity is the primary key used by the network bake.

## Identity & Security
- **Local Identity** (AD-less) + Azure Key Vault. Local DNS zone `zcoffee.com`.
- Local admin account: **`Administrator`** (the answer file sets only its password; no `LabAdmin`
  user is created). WinRM over IP uses the `.\Administrator` form.
- Secure Boot required for the cluster (re-enable before Stage 5). TPM 2.0 present.
- BitLocker (boot + data), Credential Guard, WDAC, SMB signing, drift control per ODIN "Recommended".

## DNS & naming convention
Pattern `azl<location><instance><role>`, lowercase, **no hyphens** in DNS/Azure names.
- Cluster `azljkt01clu.zcoffee.com`; nodes `azljkt01n1/n2.zcoffee.com`.
- `azljkt01rg` (resource group), `azljkt01dep` (deployment), `azljkt01loc` (custom location),
  `azljkt01kv` (Key Vault), `azljkt01diag` (diagnostics), `azljkt01wit` (cloud witness).

## Best practice
- Keep tenant IDs, subscription IDs, and secrets in the private runbook, never in the repo.
- Adapter names must match reality exactly (including spaces) or Stage 5 Network ATC fails.
