<#
First transfer of the offline Windows deployment bundle.

The bundle to fetch is a PARAMETER, not a constant. The previous version hard
coded the v2 agent bundle while the Jasna cloud work had moved to v3, so the
documented bootstrap would have delivered the wrong archive and the deployment
would have failed several minutes into a billed window. Defaulting to the Jasna
bundle keeps the common path correct; passing -Url/-Sha256 covers the other.
#>
param(
    [string]$Url = 'https://github.com/russellchen001/MosaicRestore/releases/download/jasna-cloud-offline-20261005/mosaic-jasna-airgpu-v0.10.0-v3.zip',
    [string]$Sha256 = '9578bdeb232683e1d20b2cc74e3130d5217c5b7ba211dbfe3bfd2c4d83f42030',
    [string[]]$Required = @('deploy_windows_agent.cmd','deploy_windows_agent.ps1','deploy_windows_jasna.cmd',
                            'windows_gui_agent.py','cloudflared.exe','SHA256.json','jasna-airgpu-v0.10.0.json','wheels'),
    [string]$RawBase = 'https://raw.githubusercontent.com/russellchen001/MosaicRestore/master',
    [string[]]$Overlay = @('adapters/deploy_windows_agent.ps1', 'adapters/windows_gui_agent.py')
)
$ErrorActionPreference = 'Stop'
$unpack = $null
try {
    $null = Get-Command curl.exe -ErrorAction Stop
    $root = Join-Path $env:TEMP ('MosaicP5-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $zip = Join-Path $root ([IO.Path]::GetFileName($Url))
    & curl.exe -fL --connect-timeout 10 --max-time 120 --retry 0 -sS -o $zip $Url
    if ($LASTEXITCODE -ne 0) { throw 'ZIP transfer failed or exceeded 120 seconds; do not retry in this window' }
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256.ToLower()) { throw "ZIP checksum mismatch: $actual" }
    $destination = Join-Path $root 'deploy'
    $unpack = Start-Job -ScriptBlock {
        param($archive, $target)
        Expand-Archive -LiteralPath $archive -DestinationPath $target -ErrorAction Stop
    } -ArgumentList $zip, $destination
    $null = Wait-Job $unpack -Timeout 60
    if ($unpack.State -ne 'Completed') { throw 'Unpack failed or exceeded 60 seconds' }
    Receive-Job $unpack -ErrorAction Stop | Out-Null
    foreach ($file in $Required) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $file))) { throw "Bundle missing $file" }
    }
    # The published archive is a snapshot taken before the deployment defects were
    # found. Re-publishing a 52MB bundle to carry a 10KB fix is the slower, more
    # error-prone option, so the current script is overlaid here instead. This is
    # explicit rather than silent: a window must never run a deployment whose
    # provenance nobody can state.
    foreach ($overlay in $Overlay) {
        $url = "$RawBase/$overlay"
        $leaf = [IO.Path]::GetFileName($overlay)
        & curl.exe -fL --connect-timeout 10 --max-time 30 --retry 0 -sS -o (Join-Path $destination $leaf) $url
        if ($LASTEXITCODE -ne 0) { throw "could not overlay $leaf from $url" }
        Write-Host "  overlaid $leaf from $RawBase"
    }
    Write-Host "PASS P5 first transfer: hash verified; deployment directory $destination"
    Write-Host 'NEXT: run deploy_windows_jasna.cmd (or deploy_windows_agent.cmd with verified -Application/-Ffprobe/-Python paths); do not install a missing runtime.'
} catch {
    Write-Host "FAIL P5 first transfer: $_; STOP AND SHUT DOWN AirGPU"
    exit 1
} finally {
    if ($null -ne $unpack) {
        if ($unpack.State -eq 'Running') { Stop-Job $unpack }
        Remove-Job $unpack -ErrorAction SilentlyContinue
    }
}
