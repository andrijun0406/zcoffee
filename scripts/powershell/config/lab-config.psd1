@{
    # ============================================================
    # Azure Local Lab - single source of truth (Jakarta 01)
    # Aligned with ODIN config report generated 2026-08-15.
    # No secrets here: keep passwords, subscription, and tenant in the private runbook.
    # ============================================================

    # Identity / DNS
    DnsServer      = '10.8.230.51'
    DnsSuffix      = 'zcoffee.com'

    # Cluster / Azure resource names (lowercase, no hyphens)
    ClusterName    = 'azljkt01clu'
    ResourceGroup  = 'azljkt01rg'
    DeploymentName = 'azljkt01dep'
    CustomLocation = 'azljkt01loc'
    KeyVault       = 'azljkt01kv'
    DiagStorage    = 'azljkt01diag'
    WitnessStorage = 'azljkt01wit'

    # Networking
    MgmtVlan       = 230
    StorageVlan1   = 711
    StorageVlan2   = 712
    Gateway        = '10.8.230.1'
    InfraCidr      = '10.8.230.0/24'
    InfraIpPoolStart = '10.8.230.132'
    InfraIpPoolEnd   = '10.8.230.137'
    StorageAutoIpSubnet = '10.71.0.0/16'
    HttpPort       = 8080

    # Adapter names (must match the OS-reported names for Network ATC intents)
    MgmtAdapters    = @('Integrated NIC1 Port 1-1', 'Integrated NIC1 Port 2-1')  # 10GbE, RDMA No
    StorageAdapters = @('SLOT 2 Port 1', 'SLOT 2 Port 2')                        # 25GbE, RDMA Yes (iWARP)

    # Host preparation
    LocalAdminUser = 'LabAdmin'
    iDRACUser      = 'root'

    # Firmware catalog for hardware prep. Default pulls latest from Dell online.
    # For strict Azure Local support-matrix compliance, point this at a DRM catalog
    # host pinned to the validated versions instead of always-latest downloads.dell.com.
    FirmwareCatalogUrl = 'dl.dell.com/Catalog'

    # Azure scope (fill from private runbook / ODIN report; leave blank in Git)
    SubscriptionId = ''
    TenantId       = ''

    # Nodes (HostIP from ODIN report; iDRAC = out-of-band mgmt, not in ODIN report)
    Nodes = @(
        @{ Name = 'azljkt01n1'; HostIP = '10.8.230.71'; iDRAC = '10.8.230.84'; ServiceTag = 'JF7C7J3' }
        @{ Name = 'azljkt01n2'; HostIP = '10.8.230.72'; iDRAC = '10.8.230.86'; ServiceTag = '1G7C7J3' }
    )
}
