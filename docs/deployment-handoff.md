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

## Progress state (as of 2026-09-07)

* Stage 0: DONE. Certificate service principal created; roles assigned; credentials stored locally.
* Stage 1: PASS on both nodes using the Azure Portal 2608 ISO. Embedded WIM build is `26100.33296`; post-install network bake completed for both nodes.
* Stage 2+3: PASS through the combined validation wrapper. Management and storage links are up; Hyper-V, Failover Clustering, DCB, TPM, Secure Boot, egress, and Environment Checker gates passed.
* SBE staging: PASS. Dell AX-15G `5.0.2606.1510` manifests and payload staged to `C:\SBE` on both nodes.
* Stage 4: PASS and idempotent. Both Arc machines are `Connected`, use `connection.type=gateway`, and are associated with `zcoffee-arcgw`.
* Stage 5 Validate: PASS. ARM parameter conversion, array preservation, secure runtime password injection, and template validation all pass.
* Stage 5 Deploy: NOT RUN. This is the next irreversible action.
* Stage 6: NOT RUN; depends on successful cluster deployment and convergence.

The installed `AzSHCI.ARCInstaller` is `1.2408.0.3053` and does not expose `TargetSolutionVersion`. Stage 4 and Stage 5 therefore treat partner metadata as diagnostic and require operational Arc postconditions instead: exact Arc status `Connected`, gateway mode when enabled, and Azure-side machine verification.
## OPEN ITEMS for the next session

1. Submit Stage 5 Deploy only after reviewing the What-If output; use a new deployment name such as `azljkt01dep2608`.
2. Monitor deployment until `Succeeded`; run Stage 6 only after cluster, quorum, and S2D converge.
3. Add and test the destructive lab teardown workflow (`07-dismantle-lab.ps1`) with PlanOnly and explicit confirmation.
4. Keep SBE staging in the orchestrated path so Microsoft and Dell image sources behave consistently.
5. Update the orchestrator only after the individual Stage 5 Deploy and Stage 6 runs succeed.
6. Preserve the Arc Gateway for rebuilds unless the specific test is gateway auto-creation.
## Hard-won lessons (do NOT re-learn these)
- Microsoft 2608 ISO provides the OS/SBE image baseline but does not populate Dell `C:\SBE`; stage the Dell bundle before deployment.
- SBE staging is pre-deployment; Azure Local/LCM applies it during Stage 5, while Azure Update Manager is post-deployment servicing.
- Stage 4 success is based on node/Azure postconditions, not a clean initializer return; `Trace-Execution` can occur after successful Arc resource creation.
- The old installer lacks `TargetSolutionVersion`; do not make unsupported partner metadata a hard gate.
- Windows PowerShell 5.1 unwraps single-item arrays and has fragile backtick continuation; use unary-comma array preservation and splatted cmdlet arguments.
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
