$ErrorActionPreference = 'Stop'
$unpack = $null
try {
    $null = Get-Command curl.exe -ErrorAction Stop
    $root = Join-Path $env:TEMP ('MosaicP5-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $zip = Join-Path $root 'mosaic-p5-windows-deploy-v2.zip'
    $url = 'https://github.com/russellchen001/MosaicRestore/releases/download/p5-deploy-offline-20261004/mosaic-p5-windows-deploy-v2.zip'
    & curl.exe -fL --connect-timeout 10 --max-time 60 --retry 0 -sS -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw 'ZIP transfer failed or exceeded 60 seconds; do not retry in this window' }
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne '17d40b6dac3a917ed8c7d045c42aaab0f06b1283bc27503547cb528de1cc693b') {
        throw 'ZIP checksum mismatch'
    }
    $destination = Join-Path $root 'deploy'
    $unpack = Start-Job -ScriptBlock {
        param($archive, $target)
        Expand-Archive -LiteralPath $archive -DestinationPath $target -ErrorAction Stop
    } -ArgumentList $zip, $destination
    $null = Wait-Job $unpack -Timeout 30
    if ($unpack.State -ne 'Completed') { throw 'Unpack failed or exceeded 30 seconds' }
    Receive-Job $unpack -ErrorAction Stop | Out-Null
    foreach ($file in @('deploy_windows_agent.cmd','deploy_windows_agent.ps1','windows_gui_agent.py','cloudflared.exe','SHA256.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $file) -PathType Leaf)) { throw "Bundle missing $file" }
    }
    Write-Host "PASS P5 first transfer: hash verified; deployment directory $destination"
    Write-Host 'NEXT: run deploy_windows_agent.cmd with the already-verified external application and ffprobe paths; do not install a missing runtime.'
} catch {
    Write-Host "FAIL P5 first transfer: $_; STOP AND SHUT DOWN AirGPU"
    exit 1
} finally {
    if ($null -ne $unpack) {
        if ($unpack.State -eq 'Running') { Stop-Job $unpack }
        Remove-Job $unpack -ErrorAction SilentlyContinue
    }
}
