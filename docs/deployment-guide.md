
---

### `docs/deployment-guide.md`
```markdown
# Deployment Guide

## Pre-Deployment
- Verify hardware specs
- Cabling: 25GbE Twinax (storage), 10GbE (compute/management)
- VLAN 230, subnet 10.8.230.0/24
- Validate firmware/driver/BIOS against [Dell Support Matrix](https://dell.github.io/azurestack-docs/docs/hci/supportmatrix/2606/14g-15g_hci)

## Deployment
- Install Azure Stack HCI OS
- Configure Storage Spaces Direct
- Run automation scripts:
  - `init-cluster.ps1`
  - `configure-network.ps1`
  - `deploy-s2d.ps1`
- Apply ARM templates:
  - `base-infra.json`
  - `keyvault.json`

## Post-Deployment
- Apply updates
- Configure monitoring + demo scenarios
- Document issues in `docs/troubleshooting.md`
