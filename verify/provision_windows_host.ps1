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
    [string]$PythonUrl   = 'https://api.nuget.org/v3-flatcontainer/python/3.11.9/python.3.11.9.nupkg',
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
    # Not the python.org installer. A rented Windows host answered it with 1625,
    # "installation forbidden by system policy": the image disallows Windows
    # Installer packages for this account, and no amount of per-user flags gets
    # around a policy. Asking the operator to find an administrator would also
    # break the admission rule this project is built on.
    #
    # The NuGet distribution is the same CPython laid out in a directory and
    # shipped as a plain zip. There is no installer to be refused, no registry
    # to be written and nothing to elevate, so it works on a locked-down image
    # and unprovisions by deleting a folder.
    $archive = Join-Path $env:TEMP 'mosaic-python.zip'
    $staging = Join-Path $env:TEMP 'mosaic-python-extract'
    Note 'python_source' $PythonUrl
    Invoke-WebRequest -Uri $PythonUrl -OutFile $archive -UseBasicParsing
    Note 'python_archive_mb' ('{0:N1}' -f ((Get-Item $archive).Length / 1MB))
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force

    $tools = Get-ChildItem -LiteralPath $staging -Filter python.exe -File -Recurse |
             Select-Object -First 1
    if (-not $tools) {
        Fail 'the downloaded python archive contains no python.exe'
    } else {
        if (Test-Path -LiteralPath $pythonHome) { Remove-Item -Recurse -Force $pythonHome }
        New-Item -ItemType Directory -Force -Path $pythonHome | Out-Null
        Copy-Item -Path (Join-Path $tools.DirectoryName '*') -Destination $pythonHome -Recurse -Force
    }
    Remove-Item -Force $archive -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue

    $verdict = Test-Interpreter (Join-Path $pythonHome 'python.exe')
    if ($verdict) {
        $pythonExe = Join-Path $pythonHome 'python.exe'
        Note 'python' "$pythonExe ($verdict)"
    } else {
        Fail "$pythonHome\python.exe is not a usable 3.11/3.12 AMD64 interpreter"
        $pythonExe = $null
    }
}

if ($pythonExe) {
    $pip = & $pythonExe -m pip --version 2>&1 | Select-Object -First 1
    if ("$pip" -notmatch '^pip ') {
        # A directory distribution ships ensurepip rather than a ready pip.
        & $pythonExe -m ensurepip --upgrade 2>&1 | Out-Null
        $pip = & $pythonExe -m pip --version 2>&1 | Select-Object -First 1
    }
    Note 'pip' "$pip"
    if ("$pip" -notmatch '^pip ') {
        Fail 'the interpreter has no working pip; the agent installs its wheels through it'
    }
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
# Reading the machine Path is allowed on an image that refuses to let it be
# written, so the scope has to be chosen by attempting the write, not by
# attempting the read. The user scope is enough: the agent runs as this account.
$wanted = @($ffmpegHome)
if ($pythonExe) { $wanted += (Split-Path -Parent $pythonExe) }
$wanted = @($wanted | Where-Object { Test-Path -LiteralPath $_ })
$env:Path = "$env:Path;" + ($wanted -join ';')

$written = $false
foreach ($scope in @('Machine', 'User')) {
    try {
        $parts = @([Environment]::GetEnvironmentVariable('Path', $scope) -split ';' | Where-Object { $_ })
        $added = @($wanted | Where-Object { $parts -notcontains $_ })
        if (-not $added.Count) { Note 'path_added' "already on the $scope path"; $written = $true; break }
        [Environment]::SetEnvironmentVariable('Path', (($parts + $added) -join ';'), $scope)
        Note 'path_scope' $scope
        Note 'path_added' ($added -join ' | ')
        $written = $true
        break
    } catch {
        Note "path_$($scope.ToLower())" "refused: $($_.Exception.Message.Split([char]10)[0])"
    }
}
if (-not $written) {
    # Not fatal. The deployment is told where the runtime is; PATH is a courtesy.
    Note 'path_added' "neither scope could be written; runtime stays under $RuntimeRoot"
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
