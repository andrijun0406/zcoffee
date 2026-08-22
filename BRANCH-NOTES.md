# Branch: try-jumphost (last resort)

Goal: run Stage 1 from a jump host **inside 10.8.230.0/24** so the iDRAC reads the
ISO over the DC LAN at full speed, with the Sangfor VPN entirely out of the boot
path. This is the most reliable option because it removes the two fragile
variables (VPN latency + reverse connection to a VPN client IP).

## Create the branch

```bash
git checkout main && git pull
git checkout -b try-jumphost
git add scripts/powershell/copy-to-jumphost.ps1
git commit -m "try-jumphost: stage repo + ISO onto DC jump host"
git push -u origin try-jumphost
```

## Use

```powershell
# From your PC (over VPN): stage repo + ISO onto the jump host
.\copy-to-jumphost.ps1 -JumpHost 10.8.230.225

# Then RDP to the jump host and run Stage 1 there:
.\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost 10.8.230.225 `
  -AutounattendIso ..\..\isos\autounattend.iso -StartInstallation -NoCertWarn
```

## Why this should work when VPN does not

- `-HttpHost 10.8.230.225` is a real DC-LAN IP assigned to the jump host, so the
  iDRAC pulls the ISO over 25/10GbE inside the rack — no VPN, no reverse tunnel.
- The native iDRAC HTML5 "Map CD/DVD" already proved the ISO + media path are
  good; this gives the scripted `remoteimage` path the same clean network.

## Notes

- Ensure the jump host has RACADM, PowerShell 7 (or 5.1), and inbound TCP 8080
  allowed (the preflight firewall check will prompt with the fix command).
- No `-HttpHost 2.2.2.x` here — that address only exists on the VPN client.
- Secure Boot state on the nodes is independent of where you run: if the nodes
  still fail to boot with Secure Boot enabled, apply `-DisableSecureBoot` (or
  update BIOS) regardless of jump-host vs VPN.
