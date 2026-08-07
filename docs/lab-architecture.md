# Lab Architecture

## Hardware
- 2 x Dell PowerEdge R650
- CPU, RAM, drives, NICs (see master prompt)
- rNDC NIC: Intel X710 2x10GbE + 2 x 1GbE
- PCIe: QLogic FastLinQ 41262 2x10/25GbE

## Network
- 25GbE back-to-back (storage)
- 10GbE (compute/management)
- VLAN 230, subnet 10.8.230.0/24

## Identity & Security
- Local Identity + Azure KeyVault
- DNS suffix: `zcoffee.com`

---

## DNS & Naming Convention

### Pattern

- **azl** → Azure Local environment  
- **<location>** → site code (e.g., `jkt` for Jakarta, `bdg` for Bandung, `sgp` for Singapore)  
- **<instance>** → cluster instance number or purpose (`01`, `02`, `lab`, `prod`)  
- **<role>** → cluster, node, or resource type (shortened codes)

### Role Codes
- `clu` → cluster  
- `n1`, `n2` → node 1, node 2  

### Resource Codes
- `rg` → Resource Group  
- `dep` → Deployment Name  
- `loc` → Custom Location  
- `kv` → Key Vault  
- `diag` → Diagnostic Storage  
- `wit` → Cloud Witness Storage Account  

### Examples

**Jakarta Cluster 1 (Lab)**
- Cluster → `azljkt01clu.zcoffee.com`  
- Node 1 → `azljkt01n1.zcoffee.com`  
- Node 2 → `azljkt01n2.zcoffee.com`
- Resource Group → `azljkt01rg`  
- Deployment Name → `azljkt01dep`  
- Custom Location → `azljkt01loc`  
- Key Vault → `azljkt01kv`  
- Diagnostic Storage → `azljkt01diag`  
- Cloud Witness Storage → `azljkt01wit`

---

## Best Practice  
- Use **no hyphens in DNS and Azure resource names** (Key Vault, Storage Accounts, etc.) — must be lowercase alphanumeric.  
- Apply **instance numbers** (`01`, `02`) or purpose tags (`lab`, `prod`) to distinguish clusters in the same site.  
- Keep sensitive values (tenant IDs, subscription IDs, secrets) in your private runbook, not in GitHub.
