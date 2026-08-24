# Deployment Journey — Problems, Diagnoses, and Fixes (Stage 1)

A chronological decision log of the Stage 1 (OS deployment) bring-up for the Jakarta 01
lab. It records not just the fixes but the *reasoning path* — what each attempt ruled in
or out — so a future redeploy (or a different PowerEdge model) does not have to
rediscover any of it. Symptom-to-fix lookups live in [`troubleshooting.md`](./troubleshooting.md);
this doc is the narrative.

## TL;DR — the one thing that actually mattered

The golden image would not boot for a long time. After eliminating Secure Boot, BIOS
version, the Sangfor VPN, and the HTTP server one by one, the confirmed root cause was:

> **Mounting a second iDRAC Remote File Share image (RFS2) prevents the golden ISO on
> RFS1 from enumerating as a bootable UEFI device on R650 BIOS 1.12.1.**

The durable fix: **single RFS mount**, with the answer file **slipstreamed into the golden
ISO** (`make-golden-with-unattend.ps1`, via oscdimg). Disk selection is **interactive by default**
(pick the ~223 GB BOSS volume); automatic BOSS selection is experimental/opt-in. Everything else
below is the path that led there.

## Timeline of problems and fixes

### 1. Serving the ISO over a client VPN
- **Problem:** the management PC connects via Sangfor VPN and has no `10.8.230.x` address
  (it gets a `2.2.2.x` virtual IP). The ISO server auto-detect only looks for `10.8.230.*`.
- **Fix:** pass the Sangfor-assigned IP explicitly, e.g. `-HttpHost 2.2.2.4`. The iDRAC could
  reach it (confirmed by the iDRAC pinging the VPN gateway), so the mount worked.
- **Lesson:** on a client VPN, `-HttpHost` must be your current VPN-assigned IP, and it can
  change per session — re-check `ipconfig` each time.

### 2. No Python on the management PC
- **Problem:** the original ISO server used `python -m http.server`; the PC only had the
  Microsoft Store alias stub, not real Python.
- **Fix:** rewrote `serve-iso.ps1` as a native .NET `HttpListener` server — **no Python
  dependency at all**.

### 3. Inbound firewall (the RAC0718 cascade)
- **Problem (fresh PC):** the first `remoteimage` connect failed with
  `ERROR: Unable to perform requested operation`, and the next attempt with
  `RAC0718: Remote File Share service is busy`.
- **Diagnosis:** the iDRAC accepts the connect but cannot reach `http://<PC>:8080` because
  Windows Firewall blocks inbound 8080 by default. The half-open session then **wedges the
  RFS service** — and `remoteimage -s` can still show *Disabled* while it is stuck.
- **Fix:** add an inbound TCP 8080 allow rule (once per PC). Stage 1 preflight now checks for
  it and fails fast. Recover a wedged service with `remoteimage -d` on both slots, then
  `racreset soft` if needed (iDRAC-side state — switching PCs does not clear it).

### 4. Boot failure, round 1 — Secure Boot theory
- **Problem:** the golden ISO mounted but would not boot; `Boot Failed: Virtual Optical Drive`.
- **Attempt:** Secure Boot was Enabled on old BIOS (1.4.4). Disabled it via a BIOS config job.
- **Result:** one node booted **once** to Windows Setup (EMS) — which made Secure Boot look
  like the cause. It was not the whole story.

### 5. Boot failure, round 2 — BIOS update
- **Attempt:** updated BIOS 1.4.4 → 1.12.1 to refresh the Secure Boot certificate store and
  fix the flaky one-time-boot override.
- **Result:** **still failed to boot.** This ruled out both Secure Boot and BIOS age as the
  root cause.

### 6. Boot failure, round 3 — HTTP server concurrency
- **Observation:** the iDRAC HTML5 **native Map CD/DVD** always booted the same ISO, but the
  scripted `racadm remoteimage` path did not (`no compatible bootloader available`).
- **Diagnosis:** mounting needs only light reads; **booting** needs sustained, concurrent
  HTTP Range reads. The original single-threaded `HttpListener` queued them and timed out.
- **Fix:** rewrote `serve-iso.ps1` as **multi-threaded** (runspace pool, `206 Partial Content`
  / `Content-Range`, keep-alive, disconnect-tolerant) and relaxed HTTP.sys timeouts for the
  VPN. Also added **sequential boot** (default for >1 node) so two iDRACs don't saturate the
  uplink at once. Real improvements — but the boot **still failed**.

### 7. Boot failure, round 4 — jump host (removing the VPN)
- **Attempt:** copied the repo + ISO to a jump host inside `10.8.230.0/24` and served the ISO
  on the DC LAN (`-HttpHost 10.8.230.221`), removing Sangfor from the boot path entirely.
- **Result:** **still failed** — which finally ruled out the VPN *and* the HTTP server as the
  cause. (The jump host is Windows Server Core; see the operational notes below for the
  RACADM-on-Core and `-UseBasicParsing` issues encountered here.)

### 8. Root cause found — the second RFS image
- **Observation:** in the F11 → UEFI boot menu, **"Virtual Network File 2"** (RFS2 = the small
  Autounattend ISO) was listed, but **"Virtual Network File 1"** (the golden ISO) was **absent**
  — even though `remoteimage -s` reported RFS1 Enabled.
- **Test:** detached RFS2 and mounted only the golden ISO. The node immediately booted (boot
  order fell through Windows Boot Manager → PXE → **Virtual Optical Drive**, which booted) and
  reached Windows Setup.
- **Confirmed root cause:** on R650 BIOS 1.12.1, a second mounted RFS image blocks the large
  golden ISO on RFS1 from presenting as a bootable device. The native HTML5 map always worked
  because it presents as console "Virtual Optical Drive", a different device this BIOS
  enumerates reliably.

### 9. Fix — single RFS + slipstreamed answer file
- **Change:** removed the RFS2 path from `deploy-os.ps1` / `01-deploy-os.ps1` entirely (it still
  *detaches* any stale RFS2 before mounting RFS1). Built `make-golden-with-unattend.ps1` to bake
  `Autounattend.xml` into the golden ISO so the install stays unattended over a single mount.
- **Result:** node .84 installed fully hands-off (locale, timezone, admin password auto-applied),
  pausing only at the disk screen.

### 10. Building the unattended ISO — IMAPI2 vs oscdimg
- **Attempt:** IMAPI2 COM to repack the ISO. Hit three separate failures:
  - `0x80040154 REGDB_E_CLASSNOTREG` — `IMAPI2FS.MsftFileSystemImage` unregistered on Server Core.
  - Size-cap error — default optical media cap rejected the ~8 GB payload.
  - `0xC0AAB132` — `CreateResultImage`/boot-image finalization failed on large dual-boot media.
- **Fix:** rewrote the build to use **oscdimg** (Windows ADK Deployment Tools): mount → robocopy
  to staging → drop `Autounattend.xml` → repack with UDF (`-u2 -udfver102`) + BIOS/UEFI El Torito
  (`efisys_noprompt.bin`). Also fixed a robocopy argument-quoting bug (`I:\"` → exit 16) and
  switched `/MIR` → `/E` for read-only source media.

### 11. Automatic disk selection — attempted, then reverted to opt-in
- **Goal:** remove the last manual step (picking the BOSS volume), portably across PowerEdge
  models where BOSS capacity differs (R650 BOSS-S2 223 GB vs R670 BOSS-N1 960 GB).
- **Approach:** a WinPE `RunSynchronous` step detects the BOSS RAID-1 VD by **controller identity**
  (a `BOSS` friendly name — model-agnostic, no size configured), `diskpart`-cleans it, creates the
  UEFI/GPT layout, and installs via `InstallToAvailablePartition`. A safety guard halts before
  touching any disk if detection is ambiguous (0 or >1 match), so it can never wipe an S2D disk.
- **Made it the default at first — that was wrong (see step 12).** It is now EXPERIMENTAL and
  **opt-in via `-AutoSelectBootDisk`; INTERACTIVE is the default** (the proven .84 path).

### 12. Answer file rejected on .86 — XML element order (CONFIRMED)
- **Symptom:** node .86 booted the golden ISO fine, Azure Stack HCI Setup started, then failed
  **`0x80070001 - 0x4003x`**. From Shift+F10: **no `C:\Windows\Panther\unattend.xml`** and
  **no `bootdisk-select.log`**.
- **Cause:** the auto-select rebuild emitted an `Autounattend.xml` with the `windowsPE`
  `Microsoft-Windows-Setup` child elements **out of schema order**. The sequence must be
  `ImageInstall -> RunSynchronous -> UserData`; it was assembled as `RunSynchronous -> ImageInstall
  -> UserData`. An out-of-order element makes Setup **reject the entire answer file** — so nothing
  applied (no Panther copy) and the `RunSynchronous` disk step never ran (no log), producing the
  apply-phase error. Node .84 was unaffected because its earlier ISO had only `<UserData>` (a valid
  single-element sequence).
- **Fix:** corrected the element order in `make-golden-with-unattend.ps1`, reverted the default to
  interactive, and added `make-unattend-xml-only.ps1` so the answer file can be validated LIVE via
  `setup.exe /unattend:<path>` (fast) before committing to an ~8 GB ISO rebuild.
- **Lesson:** validate answer-file XML with the `/unattend:` loop, not by rebuilding the ISO each time.

### Aside: stale "Virtual Network File 2" boot entry
- After the earlier RFS2 experiments, an orphaned **Virtual Network File 2** boot variable can
  persist in UEFI NVRAM and take boot priority even after the device is detached. Remove it via
  Boot Manager → **Delete Boot Option**, or set a persistent VCD boot with `-UseUefiBootOrder`.

## What was ruled out (so we don't retry it)

| Theory | Verdict |
|--------|---------|
| Sangfor VPN was breaking the boot stream | **Ruled out** — jump host on the DC LAN failed the same way until RFS2 was removed |
| Secure Boot on old BIOS | **Ruled out as root cause** — disabling it did not fix boot (kept off only as a workaround; re-enable before Stage 5) |
| BIOS version too old | **Ruled out** — 1.4.4 → 1.12.1 did not fix boot |
| Single-threaded HTTP server | **Real improvement, not the root cause** — multi-threaded server still failed with RFS2 mounted |
| Firmware/driver mismatch | Not the boot cause; the SBE handles the validated baseline during Stage 5 |
| **Second RFS image (RFS2) mounted** | **CONFIRMED root cause** — detaching it fixed the boot |
| **Auto disk-select answer file (`0x4003x`)** | **CONFIRMED** — XML element order (`ImageInstall`→`RunSynchronous`→`UserData`) was wrong; Setup rejected the whole file. Fixed; auto-select is now opt-in |

## The proven, repeatable Stage 1 path

```powershell
# 1. Build the unattended golden ISO once (oscdimg; single bootable image).
#    Disk selection is INTERACTIVE by default (pick ~223 GB BOSS). Add -AutoSelectBootDisk only
#    after validating the answer file live with make-unattend-xml-only.ps1 + setup.exe /unattend:.
.\make-golden-with-unattend.ps1 -OscdimgPath C:\Tools\oscdimg\oscdimg.exe `
  -GoldenIso ..\..\isos\AzureLocal24H2.<...>_A01.en-us.iso `
  -OutputIso ..\..\isos\AzureLocal-unattend.iso

# 2. (If Secure Boot is on and blocking) disable it temporarily, per node
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode <iDRAC> -DisableSecureBoot -NoCertWarn

# 3. Recreate BOSS + install, single RFS mount, one node first to validate
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -OnlyNode <iDRAC> -HttpHost <server-ip> `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
  -ISOFile ..\..\isos\AzureLocal-unattend.iso -RecreateBossVd -StartInstallation -NoCertWarn

# 4. Then both nodes (sequential boot by default)
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost <server-ip> `
  -RACADMPath 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe' `
  -ISOFile ..\..\isos\AzureLocal-unattend.iso -StartInstallation -NoCertWarn
```

## Post-install follow-ups
- Re-enable Secure Boot on both nodes before Stage 5 (Azure Local requires it).
- Rotate the iDRAC and local admin passwords (defaults were used during bring-up).
- Update BIOS/firmware to the support-matrix baseline (or let the SBE handle it at Stage 5).
- Keep `config/lab-config.psd1` aligned with the ODIN config report.
