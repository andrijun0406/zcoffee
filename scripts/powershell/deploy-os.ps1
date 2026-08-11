param(
    [string]$NodeIP,
    [string]$iDRACUser,
    [string]$iDRACPassword,
    [string]$ISOUrl,
    [string]$RACADMPath = 'racadm'
)

function Test-RACADMConnection {
    param(
        [string]$NodeIP,
        [string]$RACADMPath,
        [string]$iDRACUser,
        [string]$iDRACPassword
    )

    Write-Host "Testing iDRAC connectivity to $NodeIP..."
    $result = & $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword getsysinfo 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Unable to connect to iDRAC at $NodeIP." -ForegroundColor Red
        Write-Host $result
        throw "iDRAC connectivity test failed for $NodeIP"
    }

    Write-Host "iDRAC connectivity to $NodeIP verified."
}

Test-RACADMConnection -NodeIP $NodeIP -RACADMPath $RACADMPath -iDRACUser $iDRACUser -iDRACPassword $iDRACPassword

Write-Host "Mounting ISO to $NodeIP via RACADM..."

& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword remoteimage -c -l $ISOUrl
& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword set iDRAC.ServerBoot.NextBootDevice VCD-DVD
& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPassword serveraction powercycle

Write-Host "OS deployment initiated for $NodeIP"
