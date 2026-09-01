# ZCOFFEE - Deployment Handoff / Master Prompt

> Paste this whole file into a fresh chat to resume the project at full context.
> Opening line to use: "Continue my ZCOFFEE Azure Local automation project. Here is the full handoff brief:"

## What ZCOFFEE is
Zero-touCh Orchestration For Fabric & Edge Enablement - a PowerShell framework that deploys a
2-node Dell PowerEdge R650 Azure Local (24H2) cluster end to end, from bare-metal OS install
through Arc registration to cloud deployment, orchestrated from a Server Core jump host over a
Sangfor VPN.

## How to resume
Re-upload the current repo files (scripts/powershell/*.ps1, config/lab-config.psd1, docs/*).
The assistant's sandbox does NOT persist between sessions - the repo (GitHub) is the source of truth.
Workflow: edit on PC -> commit/push in VS Code -> `git pull` on jump host.

## Confirmed environment (single source of truth = config/lab-config.psd1)
- Nodes: azljkt01n1 (iDRAC 10.8.230.84, host 10.8.230.232, tag JF7C7J3, mgmt MAC 34:80:0D:2E:7B:B0)
         azljkt01n2 (iDRAC 10.8.230.86, host 10.8.230.235, tag 1G7C7J3, mgmt MAC 34:80:0D:2E:8B:88)
- Mgmt/Compute NIC: QLogic QL41232 rNDC, adapters "Integrated NIC 1 Port 1-1" / "Port 2-1", VLAN 230 (tagged), 10GbE link
- Storage NIC: QLogic QL41262 (SLOT 2), "SLOT 2 Port 1" / "Port 2", 25GbE switchless back-to-back, iWARP
- Boot disk: DELLBOSS VD (~223 GB RAID1). WMIC model "DELLBOSS VD" = deterministic on this platform.
- Gateway 10.8.230.1, DNS 10.8.230.51, DNS zone zcoffee.com, infra pool 10.8.230.132-.137
- Local Identity (AD-less), local admin = Administrator. Region southeastasia.
- Subscription 859c4879-999f-4cd5-a9bb-df171e8d1ad8, Tenant 2fab734c-3581-4c94-8c73-8f6dbee0ab86, RG azljkt01rg
- Service principal (Stage 0): zcoffee-azlocal-deployer, AppId 210fb971-b198-4a07-8e8f-486a483097f1,
  ObjectId 7d1ef683-a16c-4079-abb2-3038ba77ffbe, CERTIFICATE auth thumbprint FA866B907F9295EA7714445DF73822AB9072AC6A
  Roles: Azure Connected Machine Onboarding, Resource Administrator, Contributor, User Access Administrator.
- Jump host 10.8.230.221 (Server Core): RACADM installed, Az.Accounts/Az.Resources, oscdimg (ADK), NO PowerShell in Setup WinPE.

## Progress state (as of this handoff)
- Stage 0 (create SP): DONE - cert SP created, roles assigned, sp-credentials.local.json written.
- Stage 1 (deploy OS): DONE + hands-off. Slipstream ISO (make-golden-with-unattend.ps1) with:
  WMIC/cmd/diskpart BOSS auto-select (bootselect.cmd, no PowerShell) + $OEM$/SetupComplete.cmd/netbootstrap.ps1
  post-install network bake (hostname, VLAN 230, static IP, WinRM, RDP) keyed by service tag + MAC.
- Stage 2 (network validate): PASS both nodes (storage 25GbE up after DC cabling; media-state check fixed).
- Stage 3 (node readiness + Env Checker): PASS both nodes.
- Stage 4 (Arc register): DONE - both nodes Status=Connected, gateway-enabled, and Azure Local partner metadata verified.
  Resource ids: /subscriptions/859c.../resourceGroups/azljkt01rg/providers/Microsoft.HybridCompute/machines/azljkt01n1 (and .../azljkt01n2)
- Stage 5 (cloud deploy): ARM Validate passed; deployment rejected by Azure because the installed OS/solution eligibility was unsupported for the selected deployment.
- Stage 6 (validate cluster): NOT RUN.

## OPEN ITEMS for the fresh session
1. Arc Gateway: implemented. Stage 4 creates/reuses the gateway, persists its resource ID, associates existing machines, and passes `ArcGatewayID` to fresh registration.
2. Node FQDN: nodes are WORKGROUP (Local Identity) so FQDN is not azljkt01n1.zcoffee.com. If desired,
   network-bake specialize should set primary DNS suffix (NV Domain / Domain = zcoffee.com).
3. Stage 5 ARM template azuredeploy.json still required (from Dell/Microsoft Azure Local deploy package).
4. Credential store: DPAPI node-admin secret (Get-/Set-LabNodeCredential in ui-common.ps1) - captured in
   Stage 0, reused by Stages 2/3/4 so no repeated WinRM prompts. Verify wired on jump host.
5. Orchestrator (deploy-all.ps1): chains 0->6, Wait-NodeReady between reboots, gates on Arc-Connected,
   -AutoApprove for irreversible steps. Validate manually stage-by-stage before trusting it.
6. Add ZCOFFEE banner (banner.ps1 / Show-ZcoffeeBanner) to orchestrator + stage 0.

## Hard-won lessons (do NOT re-learn these)
- Azure Local Setup WinPE has NO powershell.exe and NO findstr - boot-disk logic MUST be cmd/wmic/diskpart.
- A 2nd RFS image (RFS2) breaks golden-ISO boot on this firmware - use single RFS + slipstreamed Autounattend.xml.
- unattend RunSynchronousCommand <Path> has a ~259-char limit - never embed base64 -EncodedCommand; stage a file.
- unattend windowsPE Setup element order matters (ImageInstall -> RunSynchronous -> UserData) or whole file rejected (0x4003x).
- IMAPI2 COM absent on Server Core - build ISOs with oscdimg (ADK).
- WMIC output has a trailing CR line; parse with first-non-empty + goto, not counting.
- Arc: Invoke-AzStackHciArcInitialization has NO -GraphAccessToken on current builds; use -ArmAccessToken+-AccountID or -SpnCredential.
- Guest (EXT) user -> azcmagent exit 42; onboard with the service principal instead.
- Cert SP has no secret -> cannot use -SpnCredential; use SP ARM token + explicit -AccountId (SP object id).
- Stale local azcmagent state ("Resource already deleted") -> node skipped as "Connected"; use JSON `azcmagent show -j` status + -ForceReregister (disconnect --force-local-only first).
- azcmagent "Connected" regex also matches "Disconnected" - match status field, not substring.
- Env Checker doctype XML warning is cosmetic (nested runspace) - suppress at Receive-Job/3>$null, non-blocking.
- WinRM to workgroup nodes over IP: use .\Administrator + TrustedHosts '*' (already set).
- Server Core sign-in: use -SignInMethod DeviceCode (no browser); interactive browser hangs.
- ISO serving over Sangfor VPN: jump host inside DC serves via native PowerShell HTTP (serve-iso.ps1); iDRAC pulls over LAN. Inbound 8080 firewall rule required.

## Doc set (intended purpose - keep them scoped)
- README.md          : concise "what is this / how to run", links to other docs. No long history.
- lab-architecture.md: hardware, software, versions, environment as REFERENCE for why this works here;
                        should enable a future different-architecture variant.
- troubleshooting.md : every symptom->cause->fix from Stage 1 to now. The lessons-learned record.
- deployment-journey.md: chronological history/state narrative (what happened, in order).
- deployment-guide.md: detailed runbook - every stage, every parameter explained.
- deployment-handoff.md: THIS file - the master prompt to resume.


## Partner metadata lesson

`Connected` is not a sufficient Stage 4 success condition. Azure Local eligibility also depends on the Azure Local partner registration. The current scripts require `TargetSolutionVersion` and verify `azcmagent partnerconfig get SolutionVersion --partner AzureLocal` on every node. A missing partner returns `Unknown partner: azurelocal` and blocks Stage 5.

For a single affected node, preserve the shared gateway and healthy nodes, remove only the affected Arc machine/extensions, disconnect its local agent with `--force-local-only`, and use `repair-arc-node.ps1` to re-register it.
