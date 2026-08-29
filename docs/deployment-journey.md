# Deployment Journey — The Full Saga (Problems & Fixes)

This is the chronological record of building the Stage 1 automation on the real Jakarta 01 lab
(2 x Dell PowerEdge R650, Azure Local 24H2, switchless, over Sangfor VPN). It exists so a future
redeploy never has to rediscover any of these. Each entry: **symptom -> root cause -> fix**, and
what each attempt ruled in or out.

---

## TL;DR — the hard-won truths

1. **Sangfor VPN is one-way for boot streaming.** Your PC reaches the iDRAC, but the iDRAC cannot
   reliably stream the boot image back to the PC's VPN IP during UEFI boot. **Serve the ISO from a
   jump host on the DC LAN.**
2. **A second RFS image blocks golden-ISO boot on this firmware.** Mounting an Autounattend ISO on
   `remoteimage2` (RFS2) makes the golden ISO on RFS1 refuse to boot (VNF2 shows, VNF1 absent).
   **Use a single RFS mount; slipstream the answer file into the golden ISO.**
3. **Azure Local Setup WinPE has no PowerShell and no findstr.** Any WinPE-phase automation must be
   **cmd + wmic + diskpart** only. Post-install automation (SetupComplete) runs in the full OS where
   PowerShell exists.
4. **Answer-file `RunSynchronousCommand/Path` has a ~259-char schema limit.** Embedding a base64
   `-EncodedCommand` there makes Setup reject the ENTIRE answer file (`0x80070001 - 0x40030`).
   **Stage scripts as files; keep `<Path>` short.**
5. **Nodes install with no network (APIPA only).** Reachable only via iDRAC console until the network
   bake (or a manual console one-liner) sets hostname/VLAN/IP/WinRM/RDP.
6. **The local admin is `Administrator`, not `LabAdmin`.** The answer file only sets a password; it
   does not create a user. WinRM over IP needs the `.\Administrator` qualified form.

---

## Timeline

### 1. ISO delivery: Python HTTP server -> native PowerShell server
- **Problem:** original `bootstrap` used `python -m http.server` to serve the ISO; the jump host
  (Server Core) had no Python.
- **Fix:** replaced with `serve-iso.ps1`, a native .NET `HttpListener` server (no dependency).

### 2. Firewall: RAC0720 / RAC0718 cascade
- **Symptom:** `racadm remoteimage -c` failed with `RAC0720` (can't locate image), then retries hit
  `RAC0718` (RFS service busy).
- **Root cause:** inbound **TCP 8080 blocked** on the serving PC -> the iDRAC connected but couldn't
  pull -> left a half-open RFS session that wedged the service.
- **Fix:** add inbound 8080 firewall rule; added a firewall preflight to Stage 1. Recover a wedged
  RFS with `remoteimage -d` (both slots) then `racreset soft`.

### 3. Boot failures round 1: Secure Boot on old BIOS
- **Symptom:** golden ISO mounted fine but node showed **Boot Failed: Virtual Optical Drive**, even
  from a manual F11 selection.
- **Root cause:** Secure Boot enabled on **BIOS 1.4.4** (2021-era) with an outdated certificate store
  rejecting the 2026-signed Azure Local bootloader.
- **Finding:** disabling Secure Boot let it boot to Windows Setup/EMS. So Secure Boot was *a* cause.

### 4. Boot failures round 2: BIOS update didn't fix it
- Updated BIOS 1.4.4 -> 1.12.1. **Still failed to boot** with Secure Boot re-enabled.
- **Ruled out:** old-BIOS cert store was not the whole story.

### 5. Boot failures round 3: HTTP server concurrency
- Rewrote `serve-iso.ps1` multi-threaded (runspace pool) with HTTP Range/206 support and VPN-tolerant
  timeouts, because UEFI boot issues many concurrent range reads.
- Added **sequential node boot** pacing so two iDRACs don't stream over the VPN simultaneously.
- Helped, but boot was still unreliable over the VPN.

### 6. Boot failures round 4: the VPN reverse path
- **Decisive test:** the iDRAC **HTML5 native "Map CD/DVD"** (which rides the PC's own VPN tunnel)
  booted the same ISO every time; `racadm remoteimage` (iDRAC dials back to the PC) did not.
- **Root cause:** the iDRAC->PC reverse connection over Sangfor can't sustain boot-time streaming.
- **Fix:** run Stage 1 from a **jump host inside 10.8.230.0/24** (`-HttpHost 10.8.230.221`).

### 7. Server Core gotchas on the jump host
- **RACADM install:** `msiexec /i iDRACTools_x64.msi ADDLOCAL=RACADM` failed with **error 2711 ->
  1603** ("feature RACADM not found"). Fix: drop `ADDLOCAL`, use full absolute path + `/qn`.
- **`Invoke-WebRequest` failed** with "IE engine not available" under Windows PowerShell 5.1 on
  Core. Fix: `-UseBasicParsing`.
- **IMAPI2 COM not registered** on Core (`REGDB_E_CLASSNOTREG`) -> can't build ISOs with IMAPI.
  Fix: use **oscdimg** (Windows ADK) instead.

### 8. THE root cause of boot failure: a second RFS image
- **Symptom:** with both the golden ISO (RFS1) and a tiny Autounattend ISO (RFS2) mounted, the F11
  UEFI menu showed **"Virtual Network File 2"** but **no "Virtual Network File 1"** — the golden ISO
  wasn't bootable. Detaching RFS2 -> golden ISO booted immediately.
- **Root cause:** on this iDRAC/BIOS, mounting RFS2 suppresses RFS1's boot enumeration.
- **Fix:** **single RFS mount only.** Deliver the answer file by **slipstreaming it into the golden
  ISO** (`make-golden-with-unattend.ps1`), not via a second mount. This retired the whole RFS2 path.

### 9. Slipstream ISO build problems (oscdimg)
- `robocopy /MIR` on a read-only mounted ISO root -> **exit 16**; switched to `/E` (and later a
  direct call to avoid an argument-quoting bug that mangled the source path).
- IMAPI attempts hit `FreeMediaBlocks` size cap and `0xC0AAB132` on the large dual-boot Windows ISO.
- **Fix:** extract golden ISO -> stage tree -> inject `Autounattend.xml` -> repack with
  **oscdimg** (`-u2 -udfver102`, BIOS+UEFI boot with `efisys_noprompt.bin`).

### 10. Answer file rejected: element order (0x80070001 - 0x40030)
- **Symptom:** apply-phase failure; no `C:\Windows\Panther\unattend.xml`.
- **Root cause:** `Microsoft-Windows-Setup` component elements were out of schema order.
- **Fix:** enforce `ImageInstall -> RunSynchronous -> UserData` sequence.

### 11. Auto disk-select rejected: over-length `<Path>`
- **Symptom:** same `0x40030`; answer file rejected outright again.
- **Root cause:** the auto-select `RunSynchronousCommand/Path` contained a multi-KB base64
  `-EncodedCommand`, exceeding the unattend schema's **~259-char Path limit**, so Setup discarded the
  whole answer file.
- **Fix:** stage the selection script as a **file** and keep `<Path>` short.

### 12. Auto-select still didn't run: no PowerShell in WinPE
- **Symptom:** `bootselect.ps1` present on media, but the disk screen still appeared and
  `bootdisk-select.log` was never created.
- **Root cause verified:** `dir X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` ->
  **File Not Found**. Azure Local Setup WinPE ships **without PowerShell**. A `.ps1` can never run in
  windowsPE.
- **Fix:** rewrite as **`bootselect.cmd`** using **cmd + wmic + diskpart** only. Confirmed present:
  cmd, wmic, diskpart, cscript. Confirmed **absent**: powershell, findstr.

### 13. bootselect.cmd parsing: WMIC trailing carriage return
- **Symptom (from `bootdisk-select.log`):** `BOSS 'DELLBOSS VD' disks found: 2  index:` — count 2,
  empty index, even though there is exactly one BOSS.
- **Root cause:** WMIC output has a trailing CR/blank line; `for /f ... if not "%%i"==""` counted the
  CR-only line and mis-parsed the index.
- **Fix:** take the **first valid index and stop** (`goto :BossFound`), removing the counting logic:
  ```bat
  for /f "skip=1 tokens=1" %%i in ('wmic diskdrive where "model='DELLBOSS VD'" get index') do (
      echo [%DATE% %TIME%] RAW_WMIC_VALUE=[%%i]>> "%LOG%"
      if not "%%i"=="" ( set "BOSS_INDEX=%%i" & goto :BossFound )
  )
  :BossFound
  ```
- **Safety:** exact model match `DELLBOSS VD` + never guess; if no index, log and `exit /b 0` so
  Setup falls through to manual disk selection (never aborts Setup with a non-zero code).

### 14. Networking moved out of the answer file
- Because WinPE has no PowerShell and `<Path>` is length-limited, all network config is done
  **post-install** via `$OEM$\$$\Setup\Scripts\SetupComplete.cmd -> netbootstrap.ps1`, which runs in
  the full OS (PowerShell available), keyed by Dell service tag.

### 15. IP / VLAN / identity realities (discovered live)
- Fresh installs come up with **APIPA only** — reachable solely via iDRAC console until configured.
- **VLAN 230 must be tagged host-side** (ToR port is a trunk, 230 not native). The QLogic driver
  exposes a `VLAN ID` advanced property (`VlanID`), set to `230`.
- DC admin reassigned node IPs: **`.71/.72` were taken -> use `.232` (n1) and `.235` (n2)**.
- Local admin account is **`Administrator`** (answer file sets only the password). WinRM over IP
  needs **`.\Administrator`** and the client `TrustedHosts` to include the nodes (ours was already `*`).

### 16. Final hardening of netbootstrap.ps1 (post-install)
- **NIC driver retry:** 5-minute loop (30 x 10s) — SetupComplete can run before NIC drivers finish.
- **Deterministic adapter selection:** match by **MAC** first (from `lab-config.psd1`), then
  configured name, then `QL41232`-not-`SLOT 2`; **never** "first Up adapter" — `exit 5` if ambiguous.
- **VLAN property detection:** log all advanced properties, try `VLAN ID / VLAN / Port VLAN ID /
  802.1Q VLAN ID` + registry keyword fallback (QLogic naming varies by driver).
- **WinRM validation:** `Test-WSMan` after `Enable-PSRemoting` to prove the listener is actually up.
- **Logging + markers:** `C:\Windows\Temp\netbootstrap.log` (every step) and
  `C:\Bootstrap\success.txt` (timestamp, hostname, service tag, IP, adapter).
- **Final reboot:** `shutdown /r /t 15` to settle rename + VLAN + profile.

### 17. BOSS disk-select safety design
- **Identity-first** match on `DELLBOSS VD` (model). Identity match is trusted at **any size** (so a
  future R670 BOSS-N1 960 GB or 1.92 TB isn't wrongly excluded).
- Size ceiling (`BootDiskMaxSizeGB`, default **0 = unlimited**) only ever bounds the **fallback
  guess**, never a positive identity match.
- Never touches disks in an existing S2D pool; requires exactly one candidate.

---

## What was ruled OUT (so we don't chase it again)

| Hypothesis | Verdict |
|---|---|
| VPN can't carry the ISO at all | FALSE — mount works; only iDRAC->PC **boot streaming** is unreliable |
| Old BIOS / Secure Boot cert store | Contributing, but **not** the root cause (update didn't fix boot) |
| Single-threaded HTTP server | Improved, but not the root cause |
| Corrupt ISO | FALSE — same ISO boots via native HTML5 map |
| **Second RFS image (RFS2) blocks RFS1 boot** | **CONFIRMED root cause of boot failure** |
| Auto-select logic bug | FALSE at first — WinPE simply has **no PowerShell**; later a real WMIC CR parse bug |
| Empty `<Path>` | FALSE — `<Path>` was **too long** (>259 chars), not empty |

---

## Confirmed-working end state (Stage 1)
Node `.235` (azljkt01n2), fully hands-off from a single `bootstrap-cluster.ps1 -Stage 01-deploy-os`
run against the jump host:
- WinPE `bootselect.cmd` -> `DELLBOSS VD` index 8 -> DiskPart partitions -> Setup skips disk screen.
- Post-install `netbootstrap.ps1` -> service tag `1G7C7J3` -> `azljkt01n2` / `10.8.230.235`, adapter
  matched by MAC `34:80:0D:2E:8B:88`, VLAN 230, DNS `.51`, WinRM validated, RDP enabled, success
  marker written, reboot.
- Verified from jump host: `Test-NetConnection .235 -Port 5985` and `-Port 3389` both True.


## Latest milestones (Stages 2-4)

- **Stage 1 confirmed hands-off** on .235 (azljkt01n2): WMIC `DELLBOSS VD` auto-select partitioned
  the BOSS boot disk with no prompt; post-install `netbootstrap.ps1` matched the mgmt adapter by MAC
  (`34:80:0D:2E:8B:88`), tagged VLAN 230, set 10.8.230.235/24, enabled WinRM+RDP, wrote
  `C:\Bootstrap\success.txt`, and rebooted. Node came up reachable on 5985/3389 with zero console.
- **Stage 2 PASS** after fixing a validator bug: `MediaConnectionState` is numeric (1=Connected), was
  compared to the string 'Connected' — normalized at collection. Storage `SLOT 2 Port 1/2` links up.
- **Stage 3 PASS** both nodes: Secure Boot enabled, no pending reboot, SBE staged, TPM ready, roles
  present, egress 4/4, Environment Checker connectivity green. The checker's `doctype` warning is a
  cosmetic child-runspace message (suppressed via `3>$null`).
- **Stage 4 Validate PASS**: providers registered, tokens acquired; "module missing" + "RG does not
  exist" are normal in Validate (Register mode installs modules + creates the RG).
- **Service-principal auth added** to Stages 4-5 via `Connect-AzForStage` (precedence: SP secret ->
  SP cert -> managed identity -> existing login -> device-code) for unattended runs.
