# ZCOFFEE vNext architecture

## Purpose

ZCOFFEE vNext adds a desired-state layer without replacing the proven stage scripts. The YAML spec and hardware profile describe intent; the existing orchestrator remains the execution backend during migration.

## Flow

1. Node provisioning
2. Network validation
3. SBE staging and node readiness
4. Arc registration and gateway association
5. ODIN/ARM Azure Local deployment
6. Cluster validation

## Safety model

* Preflight is read-only.
* Unsupported hardware is reported as experimental, not silently approved.
* RBAC cleanup remains explicit and confirmation-gated.
* Runtime ARM parameters remain temporary and redacted debug output never contains passwords.
* The legacy `deploy-all.ps1` remains the rollback path.

## Migration phases

### Phase 1

* `deployment-spec.yaml` and reusable hardware profiles
* preflight checks for OS build, SBE, adapters, Arc, and Azure state
* timing JSON for each vNext phase

### Phase 2

* dependency graph and blocked-state reporting
* spec-to-ODIN parameter generation
* stronger platform eligibility checks

### Phase 3

* GUI drill-down and historical deployment dashboard
* provider abstraction for ODIN, ARM, Bicep, or native Azure Local
