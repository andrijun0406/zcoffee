param(
    [string]$NodeIP,
    [string]$iDRACUser,
    [string]$iDRACPassword,
    [string]$ISOUrl,
    [string]$RACADMPath = 'racadm'
)

Write-Host "Mounting ISO to $NodeIP via RACADM..."

& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword remoteimage -c -l $ISOUrl
& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword set iDRAC.ServerBoot.NextBootDevice VCD-DVD
& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword serveraction powercycle

Write-Host "OS deployment initiated for $NodeIP"
