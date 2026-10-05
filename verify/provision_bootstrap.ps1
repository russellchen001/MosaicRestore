<#
One paste, on a provisioning window.

A provisioning window exists so that no working window ever has to download an
installer. It runs twice as much as it needs to on purpose: provision, then
preflight, so the window that follows starts from a verdict rather than a hope.

Nothing here is provider-specific and nothing here is evidence for a product
claim. It prepares a host and then asks the host whether it is prepared.
#>
param(
    [string]$RawBase = 'https://raw.githubusercontent.com/russellchen001/MosaicRestore/master'
)
$ErrorActionPreference = 'Stop'

function Fetch([string]$name) {
    # The CDN in front of raw.githubusercontent caches per edge for minutes. A
    # window that fetched an older copy ran an older script and reported an
    # older verdict, which is indistinguishable on screen from a fix that did
    # not work — and costs a window to discover. A unique query string and a
    # no-cache header make the edge ask the origin every time.
    $path = Join-Path $env:TEMP $name
    $url  = "$RawBase/verify/$name" + '?cb=' + [guid]::NewGuid().ToString('N')
    & curl.exe -fL --connect-timeout 10 --max-time 30 --retry 0 -sS `
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o $path $url
    if ($LASTEXITCODE -ne 0) { throw "could not fetch $name" }
    return $path
}

Write-Host '################ STAGE 1/2  provision ################'
& (Fetch 'provision_windows_host.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'STOP THE MACHINE NOW. The host could not be provisioned.'
    exit 1
}

Write-Host ''
Write-Host '################ STAGE 2/2  preflight ################'
& (Fetch 'preflight_airgpu.ps1')
$verdict = $LASTEXITCODE

Write-Host ''
if ($verdict -ne 0) {
    Write-Host 'STOP THE MACHINE NOW. Provisioning finished but the host still does not pass preflight.'
    exit 1
}
Write-Host 'HOST READY. STOP THE MACHINE NOW; the next window can go straight to work.'
exit 0
