# zcoffee Lab Automation

End-to-end lab automation for a **Windows Server 2025** switchless **S2D** cluster on **Dell PowerEdge R650**, aligned with:

- [**Windows Server 2025 Deployment and Operations Guide with Switchless Networking** (Dell InfoHub)](https://infohub.delltechnologies.com/en-us/t/windows-server-2025-deployment-and-operations-guide-with-switchless-networking/)
- **Dell Azure HCI / Windows HCI support matrix for 14G–15G** (firmware & driver alignment)  
  https://dell.github.io/azurestack-docs/docs/hci/supportmatrix/2512/14g-15g_hci/

The lab topology is designed to be a repeatable foundation for a **nested Azure Local / Azure Stack HCI** environment.

---

## 1. Lab Topology Overview

**Management / Control Plane**

- **jumphost-azure**  
  - Role: Domain Controller, DNS, Jump Host  
  - IP: `10.8.230.88`  
  - Domain: `zcoffe.com` (NETBIOS `ZCOFFE`)  
  - Runs: AD DS, DNS, RSAT, PowerShell automation

- **WACgw-azure**  
  - Role: Windows Admin Center Gateway (WAC)  
  - IP: `10.8.230.221`  
  - Joined to `zcoffe.com` domain  
  - Accessed from jumphost at `https://WACgw-azure:6516/`

**Cluster Nodes**

- **R650-Node1 / R650-Node2** (exact hostnames configurable in `LabInfra.json`)  
  - Hardware: Dell PowerEdge R650 (15G)  
  - OS: Windows Server 2025 Datacenter  
  - Management network: VLAN 230 (`10.8.230.x`)  
  - Switchless storage network: back-to-back **25GbE** links between nodes  
  - iDRAC:
    - Node1: `10.8.230.84`
    - Node2: `10.8.230.86`

**S2D Cluster**

- Cluster name: `S2D-CLUS01`  
- Cluster IP: `10.8.230.141`  
- Storage: 2-way mirror S2D pool with CSV volumes (e.g. `Volume01`, `Volume02` at 5.1 TB each)

All core parameters are stored centrally in `config/LabInfra.json`.

---

## 2. Repository Structure
