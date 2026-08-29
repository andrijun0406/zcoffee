# Troubleshooting

Symptom -> cause -> fix, drawn from real Jakarta 01 deployment. For the full narrative see
`deployment-journey.md`.

## Quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `RAC0720` on `remoteimage -c` | ISO URL unreachable from iDRAC (server down or **inbound 8080 blocked**) | Start `serve-iso.ps1`; add inbound TCP 8080 rule; verify with a HEAD request |
| `RAC0718` RFS service busy | Half-open RFS session from a prior blocked pull | `remoteimage -d` (both slots), then `racreset soft`, wait ~2 min |
| Boot Failed: Virtual Optical Drive (over VPN) | iDRAC->PC **reverse boot streaming** fails on Sangfor | Serve the ISO from a **jump host on the DC LAN** (`-HttpHost 10.8.230.221`) |
| F11 shows "Virtual Network File 2" but **not 1** | **Second RFS image blocks RFS1 boot** on this firmware | Single RFS mount only; slipstream the answer file into the golden ISO |
| Boot Failed with Secure Boot on, old BIOS | 2021 cert store rejects 2026-signed bootloader | Update BIOS; if still failing it's the RFS2/VPN issue, not Secure Boot |
| `0x80070001 - 0x40030` at apply, no `Panther\unattend.xml` | Answer file **rejected** (bad element order OR over-length `<Path>`) | Enforce `ImageInstall->RunSynchronous->UserData`; keep `<Path>` < 259 chars (stage scripts as files) |
| `bootselect.ps1` never runs; no `bootdisk-select.log` | **WinPE has no powershell.exe** | Use `bootselect.cmd` (cmd/wmic/diskpart only) |
| `'findstr' is not recognized` in WinPE | WinPE has no findstr | Parse WMIC with `for /f "skip=1 tokens=1"`, no findstr |
| `BOSS ... disks found: 2  index:` (empty) | WMIC trailing CR counted as a 2nd line | First-valid-index-then-`goto :BossFound`; drop counting |
| RACADM MSI: error 2711 -> 1603 | `ADDLOCAL=RACADM` feature name invalid | Install with full path + `/qn`, drop `ADDLOCAL` |
| `Invoke-WebRequest`: "IE engine not available" (Server Core, PS 5.1) | No IE DOM engine | Add `-UseBasicParsing` |
| `Failed to load XML document ... 'doctype'` during Env Checker | Cosmetic warning from the checker's own child runspace; not on the caller pipeline | Cosmetic only — results unaffected; suppress with `3>$null` on Invoke-Command, else ignore |
| Stage 4 Validate: `Module missing: Az.Resources / AzsHci.ARCInstaller` | Normal in **Validate** mode; modules install in Register mode | Expected; run `-ArcMode Register -Apply` to install + onboard |
| Stage 4 Register uses interactive login unexpectedly | `-UseExistingAzLogin` passed, no SP | Pass `-ServicePrincipalId` + `-ServicePrincipalSecret` for unattended (SP takes precedence) |
| IMAPI2 `REGDB_E_CLASSNOTREG` on Server Core | IMAPI COM not registered | Build ISOs with **oscdimg** (Windows ADK) |
| `robocopy` exit 16 mirroring a mounted ISO | `/MIR` on read-only root | Use `/E`; call robocopy directly (avoid arg-quoting mangling) |
| Node unreachable after install (APIPA 169.254.x) | Fresh install has **no IP**; network not yet applied | Network bake (SetupComplete) or iDRAC-console one-liner sets VLAN/IP |
| WinRM `Access denied` as `LabAdmin` | Wrong account — answer file sets **Administrator** only | Use `.\Administrator`; ensure client `TrustedHosts` covers the nodes |
| Stage 5 ARM can't find adapters | Adapter names in ARM don't match Windows | Use exact names incl. spaces: `Integrated NIC 1 Port 1-1`, `SLOT 2 Port 1/2` |
| Az stage: `Az.Accounts not found` | Az PowerShell modules missing on the runner | `Install-Module Az.Accounts, Az.Resources -Scope CurrentUser` |

## Recovering a wedged Remote File Share (RAC0718)
```powershell
racadm -r <idrac> -u root -p <pw> --nocertwarn remoteimage -d
racadm -r <idrac> -u root -p <pw> --nocertwarn remoteimage2 -d
racadm -r <idrac> -u root -p <pw> --nocertwarn remoteimage -s     # confirm Disabled
racadm -r <idrac> -u root -p <pw> --nocertwarn racreset soft      # if still busy; ~2 min to return
```

## Manual node network bring-up (iDRAC console, if the bake didn't run)
Nodes install with APIPA only. On the node console:
```powershell
$if = 'Integrated NIC 1 Port 1-1'
Set-NetAdapterAdvancedProperty -Name $if -DisplayName 'VLAN ID' -DisplayValue 230
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.8.230.235 -PrefixLength 24 -DefaultGateway 10.8.230.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.8.230.51
Rename-Computer -NewName azljkt01n2 -Force
Enable-PSRemoting -Force
Set-NetConnectionProfile -InterfaceAlias $if -NetworkCategory Private
Restart-Computer -Force
```
(Use `.232` / `azljkt01n1` for node 1.)

## The three forensic logs (collect these on any Stage 1 issue)
- `X:\bootdisk-select.log` — WinPE disk selection (grab via Shift+F10 during install; gone after reboot).
- `C:\Windows\Temp\netbootstrap.log` — post-install network bake, every step (service tag, adapter
  match, VLAN/IP/DNS, WinRM validation, link status).
- `C:\Bootstrap\success.txt` — proves SetupComplete finished (timestamp, hostname, tag, IP, adapter).

## WinPE capability cheat-sheet (Azure Local 24H2 Setup media)
- Present: `cmd`, `wmic`, `diskpart`, `cscript`.
- **Absent: `powershell.exe`, `findstr`.** All WinPE automation must avoid both.

## General
- Validate firmware/drivers/BIOS against the Dell Azure Local Support Matrix (14G-15G HCI).
- Keep credentials and firmware versions in the private runbook.
- Recurring "my edit didn't persist" pain came from **two clones** (`C:\zcoffee` vs `C:\LabInfra`)
  and copy->commit->pull drift. Pick one canonical clone; verify with `Select-String` before running.
