@{
    # ============================================================
    # Azure Local Lab - single source of truth (Jakarta 01)
    # Compare this file against the ODIN config report before deploying.
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
    HttpPort       = 8080

    # Host preparation
    LocalAdminUser = 'LabAdmin'
    iDRACUser      = 'root'

    # Azure scope (fill from private runbook / ODIN report; leave blank in Git)
    SubscriptionId = ''
    TenantId       = ''

    # Nodes
    Nodes = @(
        @{ Name = 'azljkt01n1'; HostIP = '10.8.230.222'; iDRAC = '10.8.230.84'; ServiceTag = 'JF7C7J3' }
        @{ Name = 'azljkt01n2'; HostIP = '10.8.230.232'; iDRAC = '10.8.230.86'; ServiceTag = '1G7C7J3' }
    )
}
