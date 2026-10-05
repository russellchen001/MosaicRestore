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
    [string]$Token = '',
    [int]$Minutes = 25,
    [string]$RawBase = 'https://raw.githubusercontent.com/russellchen001/MosaicRestore/master'
)
$ErrorActionPreference = 'Stop'

# A mandatory parameter prompts in clear text, and a token typed there ended up
# in a screenshot. Read it masked instead.
if (-not $Token) {
    $secure = Read-Host 'Token (hidden)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

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
# The receiver reports with Write-Host, which writes to the information stream
# (6), not the output stream. Capturing only the output stream left this empty
# on a transfer that had passed, and the window was stopped over a parse.
$transcript = @(& $receive -RawBase $RawBase 6>&1 | ForEach-Object { "$_" })
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
