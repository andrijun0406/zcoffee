# Azure Local Configuration Report

## Report Metadata

| Field | Value |
|-------|-------|
| Generated | 08/08/2026, 05.27.31 |
| Scenario | connected |

## Scenario & Scale

| Setting | Value |
|---------|-------|
| Scenario | connected |
| Azure Cloud | Azure Commercial |
| Azure Local Instance Region | Southeast Asia (Commercial) |
| Scale | Standard |
| Nodes | 2 |
| Cloud Witness | Cloud |

## Host Networking

| Setting | Value |
|---------|-------|
| Storage | Switchless |
| Ports | 4 |
| Intent | Management + Compute (Storage Separate) |
| Storage Auto IP | Enabled |
| Storage Subnets | Default Network ATC (10.71.0.0/16) - IPs assigned automatically |
| Storage Pool Configuration | Express |

### Port Configuration

| Port | Speed | RDMA |
|------|-------|------|
| Port 1 | 10GbE | No |
| Port 2 | 10GbE | No |
| Port 3 | 25GbE | Yes |
| Port 4 | 25GbE | Yes |

### Host Networking Diagram

![Host Networking Diagram]
## AKS Arc Network Requirements

[AKS Arc network & port requirements documentation](https://learn.microsoft.com/en-us/azure/aks/aksarc/network-system-requirements#network-port-and-cross-vlan-requirements)

| Source | Destination | Port | Description |
|--------|-------------|------|-------------|
| Management network IPs | AKS Arc VM logical network | 22 | Log collection for troubleshooting |
| Management network IPs | AKS Arc VM logical network | 6443 | Kubernetes API communication |
| AKS Arc VM logical network | Cluster IP address | 55000 | Cloud Agent gRPC server |
| AKS Arc VM logical network | Cluster IP address | 65000 | Cloud Agent gRPC authentication |

> If using separate VLANs, bi-directional cross-VLAN connectivity is required between management network and AKS Arc VM logical network for all ports above.

## Infrastructure Network

| Setting | Value |
|---------|-------|
| IP Assignment | Static |
| VLAN | Custom VLAN |
| VLAN ID | 230 |
| Infrastructure CIDR | `10.8.230.0/24` |
| IP Pool Range | `10.8.230.242 - 10.8.230.247` |
| Default Gateway | `10.8.230.1` |

### Node Configuration

| Node | Name | IP Address |
|------|------|------------|
| 1 | node1 | `10.8.230.222` |
| 2 | node2 | `10.8.230.232` |

## Identity

| Setting | Value |
|---------|-------|
| Identity Type | Local Identity |
| DNS Servers | `10.8.230.248` |
| Local DNS Zone | `zcoffee.com` |

## Security Configuration

| Setting | Value |
|---------|-------|
| Configuration | Recommended |
| WDAC | Enabled |
| Credential Guard | Enabled |
| Drift Control | Enabled |
| SMB Signing | Enabled |
| SMB Cluster Encryption | Enabled |
| BitLocker Boot Volume | Enabled |
| BitLocker Data Volumes | Enabled |

## Software Defined Networking

| Setting | Value |
|---------|-------|
| SDN Features | lnet, nsg |
| SDN Management | Arc Managed |

## Validation Summary

**Passed:** 37 &nbsp; **Warnings/Failures:** 0

| Status | Check | Details |
|--------|-------|---------|
| ✅ | Scenario selected | Selected: connected |
| ✅ | Multi-Rack is a stop-flow |  |
| ✅ | Azure Cloud selected | Selected: Azure Commercial |
| ✅ | Azure Local Instance Region selected | Selected: Southeast Asia (Commercial) |
| ✅ | Azure Local region is supported for Azure Public cloud | Microsoft lists supported Azure Public regions for Azure Local (for example: East US, South Central US, West Europe, Australia East, Southeast Asia, India Central, Canada Central, Japan East). The wizard limits choices to this supported catalog. |
| ✅ | Scale selected | Selected: Standard |
| ✅ | Nodes selected | Selected: 2 |
| ✅ | Standard disallows 16+ nodes option | Wizard disables 16+ for Standard. |
| ✅ | Storage selected | Selected: switchless |
| ✅ | Ports selected | Selected: 4 |
| ✅ | Switchless (2 nodes) blocks 1 port | Wizard disables 1 port for 2-node switchless. |
| ✅ | Switchless (2 nodes, Standard) blocks 2 ports | Wizard disables 2 ports unless Low Capacity. |
| ✅ | Intent selected | Selected: Management + Compute (Storage Separate) |
| ✅ | 4 ports disables Custom intent | Wizard disables Custom with 4 ports. |
| ✅ | Switchless (Standard) disables All Traffic intent | Wizard disables fully converged in this case. |
| ✅ | Switchless disables Compute+Storage intent | Wizard disables Compute+Storage with switchless. |
| ✅ | Outbound selected | Selected: Public Internet |
| ✅ | IP assignment selected |  |
| ✅ | Infrastructure VLAN selected |  |
| ✅ | Infra VLAN ID is valid (1-4096) | Valid VLAN IDs are integers 1–4096. Azure Local guidance emphasizes that management VLAN tagging must be configured on the physical adapters before Azure Arc registration so connectivity is preserved through deployment. |
| ✅ | Infra CIDR format is valid | Example: 192.168.1.0/24 |
| ✅ | Infra IP range has valid IPv4 start/end |  |
| ✅ | Infra range end >= start |  |
| ✅ | Infra range has at least 6 IPs | Azure Local guidance requires a management/infrastructure IP pool of at least six consecutive available IPs for infrastructure services (cluster IP, Arc Resource Bridge VM and components, and other platform services). |
| ✅ | Infra IP pool excludes node IPs | No node IPs are inside the reserved Infrastructure IP Pool range. |
| ✅ | Infra range uses private IPv4 space (RFC1918) | The Infrastructure IP pool is within private address space, which is the standard practice for internal management networks. |
| ✅ | Infra range does not overlap AKS reserved networks (10.96.0.0/12, 10.244.0.0/16) | These ranges are reserved to avoid collisions with Kubernetes networking used by Arc Resource Bridge and cluster infrastructure services. |
| ✅ | Infra range is within Infra CIDR | Wizard requires range to be within the provided CIDR. |
| ✅ | Infra CIDR does not overlap AKS reserved networks (10.96.0.0/12, 10.244.0.0/16) | Avoiding overlap prevents routing conflicts between the Infrastructure network and Kubernetes/AKS network ranges used by Azure Local infrastructure. |
| ✅ | Infra CIDR includes all node IPs | All node IPs are within the Infrastructure network CIDR. |
| ✅ | At least 1 DNS server configured | DNS is required so the nodes and infrastructure components can resolve required names (domain controllers, Arc endpoints, etc). Azure Local guidance also states DNS server IPs used by nodes/infrastructure are not supported to change after deployment, so plan this input carefully. |
| ✅ | All DNS servers are valid IPv4 | Each DNS server must be a valid IPv4 address to ensure correct resolver configuration. |
| ✅ | DNS servers do not overlap AKS reserved networks (10.96.0.0/12, 10.244.0.0/16) | Ensures the DNS servers are not placed inside the reserved Kubernetes ranges used by Arc Resource Bridge and Azure Local infrastructure. |
| ✅ | DNS servers are outside Infra range | Wizard blocks DNS servers from being inside the Infra IP pool. |
| ✅ | Local DNS Zone is provided for Local Identity | Local Identity deployments require a local DNS zone for name resolution in the environment. |
| ✅ | SDN management selected when features are enabled | When SDN features are enabled, you must choose the SDN management model so control-plane responsibilities are clear. |
| ✅ | LNET/NSG-only supports Arc management | Wizard disables On-Prem management when only LNET/NSG are selected; this combination is supported via Arc-managed SDN in this flow. |

## Decisions & Rationale

### Deployment Scenario

**Selected:** connected

### Azure Cloud & Azure Local Region

**Azure Cloud:** Azure Commercial

**Azure Local Instance Region:** Southeast Asia (Commercial)

- Your Azure cloud selection determines which endpoints, compliance boundaries, and region catalogs apply.
- Azure Local supported regions for Azure Public include: East US, South Central US, West Europe, Australia East, Southeast Asia, India Central, Canada Central, Japan East.

### Scale & Nodes

**Scale:** Standard

**Nodes:** 2

### Storage & Ports

**Storage:** Switchless

**Ports per node:** 4

- Switchless storage typically reduces the number of storage networks and impacts intent options.
- Switchless storage is generally intended for smaller clusters; larger clusters require switched storage connectivity.
- With 4 ports, the wizard disables Custom intent (insufficient ports for flexible mapping).

### Traffic Intent & Adapter Mapping

**Intent:** Management + Compute (Storage Separate)

- Splits storage traffic away from mgmt/compute to reduce contention and isolate storage behavior.

### Outbound, Arc, Proxy & Private Endpoints

**Outbound:** Public Internet

**Arc Gateway:** Enabled (Recommended)

**Proxy:** Disabled

**Private Endpoints:** Disabled

**Firewall Allow List Endpoint Requirements:** [Azure Local endpoints not redirected via Arc Gateway](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-arc-gateway-overview?tabs=portal#azure-local-endpoints-not-redirected)

- Public outbound allows direct access to required endpoints (subject to firewall allow-listing).

### IP, Infrastructure Network & VLAN

**IP:** Static

**Infra VLAN:** Custom VLAN

**Infra VLAN ID:** `230`

**Infra Network:** `10.8.230.0/24`

**Infra Range:** `10.8.230.242 - 10.8.230.247`

- Management IP strategy affects provisioning workflow and long-term operations.
- Infrastructure VLAN selection ensures consistent reachability to Arc registration and management endpoints.
- Management VLAN tagging (when required) must be configured on the physical adapters before Azure Arc registration.
- The infrastructure IP pool is designed for cluster infrastructure services; size it with headroom if you expect additional services later.

### Identity & DNS

**Identity:** Local Identity

**DNS Servers:** `10.8.230.248`

**Local DNS Zone:** `zcoffee.com`

- Local Identity mode typically requires a local DNS zone for name resolution within the environment.
- DNS settings are a critical dependency for deployment and ongoing management; ensure your chosen DNS resolvers remain reachable.
- Azure Local guidance states DNS server IPs used by nodes are not supported to change after deployment.

### Software Defined Networking (SDN)

**Features:** lnet, nsg

**Management:** Arc Managed

- SDN features require a management model decision (Arc-managed vs on-prem tooling).

---

*Generated by ODIN for Azure Local - 2026-08-07T22:27:31.001Z*
