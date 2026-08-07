# Deployment Guide

## Pre‑Deployment

### Prerequisites
- Register Partner Admin Link (PAL) for Azure solutions.
- Verify cabling instructions for switchless design (25GbE back‑to‑back for storage, 10GbE for management/compute).
- Confirm VLANs and IP layout:
  - VLAN 230 → Management/Compute (10.8.230.0/24)
  - VLAN 711 → StorageNetwork1 (Port 3)
  - VLAN 712 → StorageNetwork2 (Port 4)

### Firmware & Software Compliance
- Validate against Dell Support Matrix (14G–15G HCI).
- Document BIOS, NIC, and driver versions in private runbook.
- Ensure all nodes are updated before OS deployment.

---

## Operating System Deployment

### Golden Image ISO
- Use Dell‑provided Azure Local golden‑image ISO for baseline OS install.
- Mount ISO via iDRAC Virtual Media from management endpoint.
- Apply unattended answer file for automated installation.

### Host Networking
- Identify NICs for management/compute traffic (`Port 1`, `Port 2`).
- Identify NICs for storage traffic (`Port 3`, `Port 4`).
- Configure IP addresses:
  - Mgmt/Compute → 10.8.230.242–247
  - Storage → Auto IP assignment enabled
- Apply VLAN IDs (711, 712) for storage networks.
- Configure firewall per Dell recommendations.

---

## Node Preparation

### Hostname Assignment
- Rename nodes to match naming convention:
  - `azljkt01n1`
  - `azljkt01n2`
- Reboot after hostname change.

### IP Configuration
- Assign static IPs for management/compute:
  - `azljkt01n1` → 10.8.230.222
  - `azljkt01n2` → 10.8.230.232
- Verify DNS forwarder (10.8.230.248).

### Security Baseline
- Enable BitLocker (boot + data volumes).
- Enforce Credential Guard, WDAC, SMB signing.
- Configure drift control enforcement.

---

## Post‑Deployment

### Updates & Maintenance
- Apply SBE packages for Azure Local updates.
- Document GPU integration or optional features if used.

### Monitoring & Lifecycle
- Use Dell OpenManage Integration with Windows Admin Center (WAC).
- Monitor compliance with Dell Support Matrix.
- Reference private runbook for credentials and sensitive values.

---

## Best Practice
- Keep sensitive values (localAdminUsername, localAdminPassword, subscription IDs) in private OneNote runbook.
- Public repo should reference Dell docs and conventions, but never expose credentials.
- Cross‑reference: *“See private runbook for credentials and firmware versions.”*
