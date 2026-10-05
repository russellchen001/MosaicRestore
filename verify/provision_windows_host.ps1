<#
One-time provisioning of a rented Windows GPU host, run OUTSIDE any working
window.

WHY THIS EXISTS
    The preflight found two things missing that no amount of care inside a paid
    window can fix cheaply: there was no ffprobe.exe, so a restored clip could
    not have been validated, and there was no usable CPython 3.11/3.12 AMD64, so
    the agent's bundled win_amd64 wheels had nowhere to install. Installing
    either one inside a working window is forbidden, and rightly so: a download
    and an MSI are minutes of GPU time spent on something that has nothing to do
    with restoration.

    So this runs once, on its own short window, and writes everything to the
    host's persistent disk. Afterwards every working window starts with the
    runtime already present. If the host is rebuilt, this is run again.

WHAT IT IS NOT
    Not bound to any provider. It takes no account, no machine name and no
    endpoint; it asks the operating system what it has and fills in what is
    missing. Any Windows host with a working NVIDIA driver can be provisioned by
    it. It also installs nothing GPU-related: a host whose driver is broken is a
    host to replace, not to patch.

    It is not evidence for any product claim. A clean exit means the host now
    carries the prerequisites the deployment assumes; it says nothing about
    restoration.

IDEMPOTENCE
    Every step checks first and skips if satisfied, so re-running costs the
    verification only. Nothing is uninstalled and nothing already on the host is
    overwritten.
#>
param(
    [string]$RuntimeRoot = 'C:\MosaicRuntime',
    [string]$PythonUrl   = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe',
    [string]$FfmpegUrl   = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
    [string]$Report      = "$env:TEMP\mosaic-provision.json",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$started = Get-Date
$facts   = [ordered]@{}
$failed  = @()

function Note([string]$label, [string]$value) {
    $facts[$label] = $value
    Write-Host ("  {0,-20} {1}" -f $label, $value)
}
function Fail([string]$reason) {
    $script:failed += $reason
    Write-Host "  FAILED               $reason"
}

Write-Host "== host =="
Note 'computer' $env:COMPUTERNAME
Note 'os'       (Get-CimInstance Win32_OperatingSystem).Caption
Note 'arch'     $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    Write-Host ''
    Write-Host 'PROVISION ABORTED: this host is not AMD64. The agent wheels are win_amd64.'
    exit 1
}
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
Note 'runtime_root' $RuntimeRoot

# ---------------------------------------------------------------- python ----
# A Store alias (WindowsApps\python.exe) answers to the name and then refuses to
# run, so a candidate is accepted only when it reports its own version and
# architecture. The architecture half is not pedantry: winget has already handed
# this project an ARM64 interpreter on an AMD64 request.
Write-Host "== python =="
$pythonHome = Join-Path $RuntimeRoot 'python311'
$pythonExe  = Join-Path $pythonHome 'python.exe'

function Test-Interpreter([string]$exe) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
    if ($exe -like '*\WindowsApps\*') { return $null }
    try {
        $probe = & $exe -c "import sys,platform;print('%d.%d %s' % (sys.version_info[0], sys.version_info[1], platform.machine()))" 2>&1 |
                 Select-Object -First 1
    } catch { return $null }
    if ("$probe" -match '^3\.(11|12) AMD64$') { return "$probe" }
    return $null
}

$existing = $null
foreach ($candidate in @($pythonExe) + @(Get-Command python.exe -All -ErrorAction SilentlyContinue |
                                         Select-Object -ExpandProperty Source -Unique)) {
    $verdict = Test-Interpreter $candidate
    if ($verdict) { $existing = [pscustomobject]@{ Path = $candidate; Version = $verdict }; break }
}

if ($existing -and -not $Force) {
    Note 'python' "already usable: $($existing.Path) ($($existing.Version))"
    $pythonExe = $existing.Path
} else {
    $installer = Join-Path $env:TEMP 'mosaic-python-amd64.exe'
    Note 'python_source' $PythonUrl
    Invoke-WebRequest -Uri $PythonUrl -OutFile $installer -UseBasicParsing
    Note 'python_installer_mb' ('{0:N1}' -f ((Get-Item $installer).Length / 1MB))

    # A per-user install into our own directory, so nothing on the host is
    # adopted or displaced and no elevation is needed. InstallAllUsers=0 also
    # sidesteps the WiX provider-key collision that made a previous x64
    # installer exit 0 while doing nothing.
    $arguments = @('/quiet', 'InstallAllUsers=0', "TargetDir=$pythonHome",
                   'Include_launcher=0', 'Include_test=0', 'AssociateFiles=0',
                   'Shortcuts=0', 'PrependPath=0', 'Include_pip=1')
    $run = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    Note 'python_installer_exit' "$($run.ExitCode)"

    $verdict = Test-Interpreter (Join-Path $pythonHome 'python.exe')
    if ($verdict) {
        $pythonExe = Join-Path $pythonHome 'python.exe'
        Note 'python' "$pythonExe ($verdict)"
    } else {
        Fail "the installer exited $($run.ExitCode) but $pythonHome\python.exe is not a usable 3.11/3.12 AMD64 interpreter"
        $pythonExe = $null
    }
}

if ($pythonExe) {
    try {
        & $pythonExe -m pip --version 2>&1 | Select-Object -First 1 | ForEach-Object { Note 'pip' "$_" }
    } catch { Fail 'the interpreter has no working pip; the agent installs its wheels through it' }
}

# ---------------------------------------------------------------- ffmpeg ----
# ffprobe is what decides whether a restored file is a valid video. Without it
# the chain can only report that a file exists, which is not the same claim.
Write-Host "== ffmpeg =="
$ffmpegHome = Join-Path $RuntimeRoot 'ffmpeg\bin'
$ffprobe    = Join-Path $ffmpegHome 'ffprobe.exe'

$presentElsewhere = $null
if (-not (Test-Path -LiteralPath $ffprobe)) {
    $presentElsewhere = (Get-Command ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

if ((Test-Path -LiteralPath $ffprobe) -and -not $Force) {
    Note 'ffprobe' "already present: $ffprobe"
} elseif ($presentElsewhere -and -not $Force) {
    Note 'ffprobe' "already present: $presentElsewhere"
    $ffprobe = $presentElsewhere
} else {
    $archive = Join-Path $env:TEMP 'mosaic-ffmpeg.zip'
    $staging = Join-Path $env:TEMP 'mosaic-ffmpeg-extract'
    Note 'ffmpeg_source' $FfmpegUrl
    Invoke-WebRequest -Uri $FfmpegUrl -OutFile $archive -UseBasicParsing
    Note 'ffmpeg_archive_mb' ('{0:N1}' -f ((Get-Item $archive).Length / 1MB))
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force

    $found = Get-ChildItem -LiteralPath $staging -Filter ffprobe.exe -File -Recurse |
             Select-Object -First 1
    if (-not $found) {
        Fail 'the downloaded archive contains no ffprobe.exe'
    } else {
        New-Item -ItemType Directory -Force -Path $ffmpegHome | Out-Null
        Copy-Item -Path (Join-Path $found.DirectoryName '*.exe') -Destination $ffmpegHome -Force
        Note 'ffprobe' $ffprobe
    }
    Remove-Item -Force $archive -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $ffprobe) {
    $banner = & $ffprobe -hide_banner -version 2>&1 | Select-Object -First 1
    Note 'ffprobe_version' "$banner"
    if ("$banner" -notmatch 'ffprobe version') { Fail 'ffprobe.exe did not report a version' }
} else {
    Fail 'no ffprobe.exe after provisioning'
}

# ------------------------------------------------------------------ PATH ----
# Put the runtime on the machine PATH so a later window finds it without being
# told where it is. Per-machine when we are allowed to, per-user otherwise: the
# admission rule forbids requiring an administrator.
Write-Host "== path =="
$scope = 'Machine'
try { [Environment]::GetEnvironmentVariable('Path', 'Machine') | Out-Null }
catch { $scope = 'User' }
$wanted = @($ffmpegHome)
if ($pythonExe) { $wanted += (Split-Path -Parent $pythonExe) }
try {
    $current = [Environment]::GetEnvironmentVariable('Path', $scope)
    $parts   = @($current -split ';' | Where-Object { $_ })
    $added   = @()
    foreach ($entry in $wanted) {
        if (Test-Path -LiteralPath $entry) {
            if ($parts -notcontains $entry) { $parts += $entry; $added += $entry }
        }
    }
    if ($added.Count) {
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), $scope)
        Note 'path_scope' $scope
        Note 'path_added' ($added -join ' | ')
    } else {
        Note 'path_added' 'nothing to add'
    }
    $env:Path = "$env:Path;" + ($wanted -join ';')
} catch {
    Note 'path_added' "could not be written ($scope): $($_.Exception.Message)"
}

# ---------------------------------------------------------------- report ----
$facts['elapsed_seconds'] = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$facts['failures']        = $failed
try { $facts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8 } catch {}

Write-Host ''
if ($failed.Count) {
    Write-Host "PROVISION FAILED ($($facts['elapsed_seconds'])s)"
    $failed | ForEach-Object { Write-Host "  - $_" }
    Write-Host "report: $Report"
    Write-Host 'STOP THE MACHINE NOW. Nothing here is fixed by waiting.'
    exit 1
}
Write-Host "PROVISION OK in $($facts['elapsed_seconds'])s"
Write-Host "report: $Report"
Write-Host 'Run verify/preflight_airgpu.ps1 once to confirm, then stop the machine.'
exit 0
