# ZCOFFEE vNext Automation Testing Guide

This guide explains how to validate and test the **spec-driven, modular vNext automation** on branch `feature/zcoffee-vnext`.

## Canonical entry points

- **Primary orchestrator:** `scripts/powershell/vnext/Invoke-ZcoffeeDeployment.ps1`
- **Compatibility shim:** `scripts/powershell/vnext/deploy-all-vnext.ps1` (forwards to the canonical orchestrator)
- **Read-only preflight:** `scripts/powershell/vnext/zcoffee-preflight.ps1` (compatibility wrapper) or `Invoke-ZcoffeePreflight` from `scripts/powershell/vnext/lib/Preflight.ps1`
- **Non-destructive test helper:** `scripts/powershell/vnext/Test-ZcoffeeDeployment.ps1`

Modular components (no overlapping orchestration logic):
- `scripts/powershell/vnext/lib/Spec.ps1` — YAML spec/profile loading, path resolution, validation
- `scripts/powershell/vnext/lib/Timing.ps1` — per-phase timing and JSON report persistence
- `scripts/powershell/vnext/lib/Preflight.ps1` — spec-driven read-only node/Azure/Arc checks

Proven execution backends reused by vNext:
- `scripts/powershell/deploy-all.ps1` (legacy stage orchestrator)
- `scripts/powershell/stage-sbe.ps1` (SBE staging)

## Prerequisites

### Local tooling
- Windows PowerShell 5.1+ or PowerShell 7+ (run from a jump host / management machine as appropriate)
- Git repo checked out: `C:\zcoffee-vnext` (or your working copy path)
- **For spec/profile YAML loading:** `powershell-yaml` module
  ```powershell
  Install-Module -Name powershell-yaml -Scope CurrentUser -Force
  ```
- **For Azure preflight/execution checks:** Az modules as needed by the environment
  - `Az.Accounts`, `Az.Resources`, `Az.ConnectedMachine` (preflight Azure/Arc checks)
  - `Az.CustomLocation`, `Az.StackHCI` (Arc registration / Azure Local flows in proven scripts)
- **For node checks and proven stages:** WinRM connectivity to target nodes (port 5985/Negotiate as used by scripts), local admin credentials available to `ui-common.ps1`/lab config helpers

### Inputs
- Deployment spec: `scripts/powershell/vnext/deployment-spec.yaml` (or your spec)
- Hardware profile: set in spec (`hardwareProfile`) or pass `-ProfileFile`
- For real execution: Azure subscription/tenant, ARM template/parameter files, node reachability, and (for OS deploy) ISO/HTTP host inputs
- **Do not store secrets in the spec** (spec is intended for non-secret desired state)

## 1. PowerShell syntax / parse checks (safe, no environment access)

Run from the repo root (or adjust paths):

```powershell
$files = @(
  'scripts\powershell\vnext\Invoke-ZcoffeeDeployment.ps1',
  'scripts\powershell\vnext\Test-ZcoffeeDeployment.ps1',
  'scripts\powershell\vnext\deploy-all-vnext.ps1',
  'scripts\powershell\vnext\zcoffee-spec.ps1',
  'scripts\powershell\vnext\zcoffee-timing.ps1',
  'scripts\powershell\vnext\zcoffee-preflight.ps1',
  'scripts\powershell\vnext\lib\Spec.ps1',
  'scripts\powershell\vnext\lib\Timing.ps1',
  'scripts\powershell\vnext\lib\Preflight.ps1'
)
foreach ($f in $files) {
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { throw "Parse errors in $f" }
  "$f : OK"
}
```

## 2. Spec/profile validation and resolved-path preview (safe)

Uses `Test-ZcoffeeDeployment.ps1` to load YAML, validate required fields and referenced files, and print the resolved execution preview (including proven backend paths and timing output directory). No deployment is performed.

```powershell
cd C:\zcoffee-vnext
.\scripts\powershell\vnext\Test-ZcoffeeDeployment.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' `
  -TenantId '<tenant-id>'
```

Notes:
- `-SubscriptionId`/`-TenantId` can be passed explicitly or populated in `deployment-spec.yaml` (`azure.subscriptionId`, `azure.tenantId`).
- Expected behavior for the default sample spec may include warnings (e.g. missing/experimental profile details or missing template/parameter files if they are not present locally) — treat validation errors as blockers.
- The helper verifies that the proven backend scripts resolve to `scripts\powershell\deploy-all.ps1` and `scripts\powershell\stage-sbe.ps1`.

## 3. Read-only preflight (requires environment access)

Preflight is **read-only**: it validates spec/profile, checks WinRM node state (OS build, expected adapters, SBE files, local `azcmagent` status/mode), and optionally checks Azure context and Arc resources. It does **not** deploy, but it does connect to nodes/Azure as specified.

### 3a. Local/spec-only style checks (no nodes/Azure)
Not available as a single flag because preflight performs node checks by design; use Step 2 for safe local validation.

### 3b. Preflight with selective skips (recommended staged testing)

```powershell
# Nodes + hardware/OS/SBE checks only (no Azure/Arc API checks)
.\scripts\powershell\vnext\Test-ZcoffeeDeployment.ps1 -RunPreflight -SkipAzure -SkipArc `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>'

# Add Azure context/Arc checks when logged in and resources exist
.\scripts\powershell\vnext\Test-ZcoffeeDeployment.ps1 -RunPreflight -SkipSbe `
  -UseExistingAzLogin `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>'
```

Direct wrapper usage:
```powershell
.\scripts\powershell\vnext\zcoffee-preflight.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -ProfileFile .\scripts\powershell\vnext\profiles\dell-ax-15g-switchless.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>' `
  -UseExistingAzLogin -SkipArc -SkipAzure
```

## 4. Orchestrator dry-run / controlled execution

`Invoke-ZcoffeeDeployment.ps1` runs preflight (unless `-SkipPreflight`), optionally stages SBE, records timing, and invokes the proven `deploy-all.ps1` backend.

### 4a. Dry-run pass-through (recommended before real execution)
```powershell
.\scripts\powershell\vnext\Invoke-ZcoffeeDeployment.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>' `
  -Stages 1,2,3,4,5,6 `
  -DryRun -AutoApprove
```

- `-DryRun` is forwarded to the proven backend where supported; **verify the backend behavior for the selected stages in your environment**.
- Preflight/SBE staging (if requested) are real operations when executed — use skips intentionally.
- Timing JSON is written to the spec telemetry output directory (default `logs/` relative to spec dir): `timing-<DeploymentId>.json`.

### 4b. Preflight-only via orchestrator (no stage execution path)
There is no `-PreflightOnly` switch; for preflight-only validation use Step 3 (`Test-ZcoffeeDeployment.ps1 -RunPreflight` or `zcoffee-preflight.ps1`).

### 4c. Real deployment (destructive / environment-changing)
Only run in the target lab environment with approvals and backups appropriate to your change window.

```powershell
.\scripts\powershell\vnext\Invoke-ZcoffeeDeployment.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>' `
  -Stages 1,2,3,4,5,6 `
  -AutoApprove
```

Optional SBE staging (before backend execution, with post-SBE preflight unless skipped):
```powershell
.\scripts\powershell\vnext\Invoke-ZcoffeeDeployment.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>' `
  -StageSbe -SbeSourcePath 'C:\path\to\SBE' `
  -AutoApprove
```

Include OS deploy (Stage 1) requires HTTP host and ISO inputs (CLI or spec `deployment.httpHost`/`deployment.isoFile`):
```powershell
.\scripts\powershell\vnext\Invoke-ZcoffeeDeployment.ps1 `
  -SpecFile .\scripts\powershell\vnext\deployment-spec.yaml `
  -SubscriptionId '<sub-id>' -TenantId '<tenant-id>' `
  -IncludeOsDeploy -HttpHost '192.168.200.15' -ISOFile 'AzureLocal24H2.26100.xxxx.en-us.iso' `
  -AutoApprove
```

## 5. What to verify

- **Spec validation:** no errors; warnings understood (unsupported/experimental profile, defaults, missing optional data)
- **Path resolution:** template/parameter, proven backend (`..\deploy-all.ps1`), `stage-sbe.ps1`, and timing directory resolve correctly for the chosen spec location
- **Preflight output:** per-check PASS/WARN/FAIL table and summary; failures identify OS build, adapters, SBE, Arc agent/gateway mode, WinRM, or Azure/Arc mismatches
- **Timing report:** `timing-<DeploymentId>.json` created with stages/status/durations (including on failure where possible)
- **Backend invocation:** correct stage selection and node/IP/admin/template parameters derived from spec/overrides

## 6. Environment and safety notes

- **Destructive stages:** OS deployment/reimaging, Arc registration, and Azure Local/cluster deployment can modify or reprovision infrastructure. Test with `-DryRun`, limited `-Stages`, and non-production targets first.
- **Credentials/secrets:** passed via existing mechanisms (e.g. `ui-common.ps1`/lab config, environment, or interactive prompts); never commit secrets to the spec.
- **Network prerequisites:** management host must reach nodes (WinRM) and Azure endpoints as required by selected stages; disconnected/ARC gateway scenarios depend on your environment configuration.
- **Rollback path:** vNext reuses the proven `scripts/powershell/deploy-all.ps1` backend; legacy/manual stage scripts remain available per architecture.
- **Compatibility wrappers:** `deploy-all-vnext.ps1`, `zcoffee-spec.ps1`, `zcoffee-timing.ps1`, and `zcoffee-preflight.ps1` are retained as shims/wrappers to avoid breaking existing entrypoint names while keeping a single modular implementation.
