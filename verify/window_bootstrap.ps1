<#
One paste, inside a paid window.

Every earlier plan asked a person to run three scripts in sequence and to judge,
between each one, whether the output allowed the next. That judgement happens
while a machine bills by the minute and a remote desktop streams over video,
which is the worst possible place to ask anyone to read carefully. So the three
stages run here, in order, and the stop rule is the script's, not the operator's:
any stage that does not pass ends the run and says to stop the machine.

It reads, transfers and deploys. It does not start, stop or purchase any cloud
resource, and it does not begin restoration; the controlling machine does that
once the relay endpoint below is known.
#>
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [int]$Minutes = 20,
    [string]$RawBase = 'https://raw.githubusercontent.com/russellchen001/MosaicRestore/master'
)
$ErrorActionPreference = 'Stop'

function Fetch([string]$name) {
    $path = Join-Path $env:TEMP $name
    & curl.exe -fL --connect-timeout 10 --max-time 30 --retry 0 -sS -o $path "$RawBase/verify/$name"
    if ($LASTEXITCODE -ne 0) { throw "could not fetch $name" }
    return $path
}

Write-Host '################ STAGE 1/3  preflight ################'
$preflight = Fetch 'preflight_airgpu.ps1'
& $preflight
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'STOP THE MACHINE NOW. The machine does not carry what the deployment assumes.'
    exit 1
}

Write-Host ''
Write-Host '################ STAGE 2/3  transfer #################'
$receive = Fetch 'receive-p5.ps1'
$transcript = & $receive
$transcript | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { Write-Host ''; Write-Host 'STOP THE MACHINE NOW. The bundle did not transfer.'; exit 1 }
$line = $transcript | Where-Object { $_ -match 'deployment directory (.+)$' } | Select-Object -Last 1
if (-not $line -or $line -notmatch 'deployment directory (.+)$') {
    Write-Host 'STOP THE MACHINE NOW. The transfer reported no deployment directory.'
    exit 1
}
$deploy = Join-Path $Matches[1].Trim() 'deploy_windows_agent.ps1'
# The overlay is what carries the deployment fixes; running the snapshot instead
# would silently reintroduce every defect they closed.
if (-not ($transcript -match 'overlaid deploy_windows_agent\.ps1')) {
    Write-Host 'STOP THE MACHINE NOW. The current deployment script was not overlaid.'
    exit 1
}

Write-Host ''
Write-Host '################ STAGE 3/3  deployment ###############'
Write-Host 'Leave this window open: closing it stops the agent and the relay.'
Write-Host ''
& $deploy -Token $Token -Minutes $Minutes
