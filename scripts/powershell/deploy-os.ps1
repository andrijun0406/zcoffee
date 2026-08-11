param(
    [string]$NodeIP,
    [string]$iDRACUser,
    [string]$iDRACPassword,
    [string]$ISOUrl
)

Write-Host "Mounting ISO to $NodeIP via RACADM..."

racadm -r $NodeIP -u $iDRACUser -p $iDRACPassword remoteimage -c -l $ISOUrl
racadm -r $NodeIP -u $iDRACUser -p $iDRACPassword set iDRAC.ServerBoot.NextBootDevice VCD-DVD
racadm -r $NodeIP -u $iDRACUser -p $iDRACPassword serveraction powercycle

Write-Host "OS deployment initiated for $NodeIP"
