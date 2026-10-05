<#
First minute of a paid AirGPU window: read-only facts, then a verdict.

WHY THIS EXISTS
    Four paid windows have ended before the restoration chain was ever reached,
    and in each one the blocking fact was knowable in seconds: a stale balance, a
    bundle that did not match, a runtime the deployment could not locate. The
    machine was billed for minutes while a script discovered them one failure at
    a time.

    This asks every machine-dependent question at once, before anything is
    deployed, uploaded or started. It reads; it never installs, never launches
    the restoration application for work, never writes outside its own report.
    A blocking answer means stop the machine now, having spent about a minute.

WHAT A PASS MEANS
    Only that this machine still carries what the deployment assumes. It is not
    product acceptance and proves nothing about restoration quality.
#>
param(
    [string]$Application = '',
    [string]$Report = "$env:TEMP\mosaic-preflight.json",
    [string]$BundleUrl = 'https://github.com/russellchen001/MosaicRestore/releases/download/jasna-cloud-offline-20261005/mosaic-jasna-airgpu-v0.10.0-v3.zip',
    [int]$MinimumFreeGb = 12
)

$ErrorActionPreference = 'Continue'
$facts = [ordered]@{}
$blockers = @()
$started = Get-Date

function Note([string]$label, [string]$value) {
    $facts[$label] = $value
    Write-Host ("  {0,-22} {1}" -f $label, $value)
}
function Block([string]$reason) {
    # $script:, not $blockers. A bare += inside a function reads the parent's
    # array and then assigns a new local one, so every blocker this script found
    # was discarded and every run ended in PREFLIGHT PASS. A preflight that
    # cannot fail is worse than no preflight: it is an invitation to deploy onto
    # a host it just finished disqualifying.
    $script:blockers += $reason
    Write-Host "  BLOCKER                $reason"
}

Write-Host '== machine =='
Note 'computer' $env:COMPUTERNAME
Note 'os' (Get-CimInstance Win32_OperatingSystem).Caption
Note 'arch' $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Block "architecture $env:PROCESSOR_ARCHITECTURE; the bundled wheels and cloudflared are win_amd64" }

Write-Host '== gpu =='
# The adapter is asked for in three independent ways, because a single negative
# answer from nvidia-smi has already been mistaken for an absent GPU: on a
# streaming host the driver can be present and working (NVENC is carrying the
# stream) while nvidia-smi.exe simply is not on PATH.
$nvDisplay = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'NVIDIA|Tesla|TU104' })
Note 'gpu_device' ($(if ($nvDisplay.Count) {
    ($nvDisplay | ForEach-Object { "$($_.Name) [$($_.Status)] drv $($_.DriverVersion)" }) -join ' | '
} else { 'none in Win32_VideoController' }))

$smiPath = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $smiPath) {
    $smiPath = @("$env:SystemRoot\System32\nvidia-smi.exe",
                 "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                 "$env:ProgramW6432\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
               Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
Note 'nvidia_smi_path' ($(if ($smiPath) { $smiPath } else { 'NOT FOUND' }))

$smi = $null
if ($smiPath) {
    $global:LASTEXITCODE = 0
    try {
        $smi = & $smiPath --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1 |
               Select-Object -First 1
    } catch { $smi = $null }
    if ($LASTEXITCODE -ne 0) { Note 'nvidia_smi_exit' "$LASTEXITCODE"; $smi = $null }
}

if ($smi) {
    Note 'gpu' "$smi"
    if ("$smi" -notmatch 'T4') { Note 'gpu_warning' 'not a Tesla T4; the pinned TensorRT engines were built for T4' }
} elseif ($nvDisplay.Count) {
    # Driver and adapter are there; only the query tool answered badly. TensorRT
    # loads through the driver, not through nvidia-smi, so this is a warning.
    Note 'gpu' 'present per Win32_VideoController; nvidia-smi unavailable'
    Note 'gpu_warning' 'nvidia-smi could not be queried; GPU presence inferred from the display adapter'
} else {
    Block 'no NVIDIA adapter in Win32_VideoController and nvidia-smi unavailable'
    Note 'gpu' 'unavailable'
}

Write-Host '== jasna runtime =='
$candidates = @()
if ($Application -and (Test-Path -LiteralPath $Application -PathType Leaf)) {
    $candidates = @($Application)
} else {
    $roots = @('C:\Jasna', 'D:\Jasna', "$env:USERPROFILE\Jasna", "$env:USERPROFILE\Desktop",
               "$env:USERPROFILE\Downloads", "$env:ProgramData\Jasna")
    $candidates = @($roots | Where-Object { Test-Path $_ } | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter jasna.exe -File -Recurse -Depth 4 -ErrorAction SilentlyContinue
    } | Select-Object -ExpandProperty FullName -Unique)
}
Note 'jasna_candidates' ($(if ($candidates.Count) { $candidates -join ' | ' } else { 'none' }))

$chosen = $null
foreach ($candidate in $candidates) {
    $weights = Join-Path (Split-Path -Parent $candidate) 'model_weights'
    $detector = Test-Path -LiteralPath (Join-Path $weights 'lada_mosaic_detection_model_v4_fast.pt')
    $restorer = Test-Path -LiteralPath (Join-Path $weights 'lada_mosaic_restoration_model_generic_v1.2.pth')
    $engines = @()
    if (Test-Path $weights) {
        $engines = @(Get-ChildItem -LiteralPath $weights -Filter *.engine -File -ErrorAction SilentlyContinue)
    }
    $score = @($detector, $restorer, ($engines.Count -gt 0)) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
    Write-Host ("  candidate              {0} (detector={1} restorer={2} engines={3})" -f $candidate, $detector, $restorer, $engines.Count)
    if (-not $chosen -or $score -gt $chosen.Score) {
        $chosen = [pscustomobject]@{ Path = $candidate; Score = $score; Engines = $engines }
    }
}

if (-not $chosen) {
    Block 'no jasna.exe found; the deployment cannot locate a runtime'
} else {
    Note 'jasna_path' $chosen.Path
    if ($chosen.Score -lt 3) { Block "the chosen runtime is incomplete (completeness $($chosen.Score)/3)" }
    # A prebuilt engine is not an optimisation here: compiling one inside a billed
    # window is forbidden, and would consume the whole window if attempted.
    Note 'tensorrt_engines' ($(if ($chosen.Engines.Count) { ($chosen.Engines | Select-Object -ExpandProperty Name) -join ', ' } else { 'NONE' }))
    if ($chosen.Engines.Count -eq 0) { Block 'no prebuilt .engine cache; paid-window compilation is forbidden' }

    $version = 'unreadable'
    try {
        $probe = Start-Process -FilePath $chosen.Path -ArgumentList '--version' -NoNewWindow -PassThru `
                     -RedirectStandardOutput "$env:TEMP\jasna-version.txt" -RedirectStandardError "$env:TEMP\jasna-version-err.txt"
        if (-not $probe.WaitForExit(30000)) { $probe.Kill(); $version = 'timed out after 30s' }
        else { $version = ((Get-Content "$env:TEMP\jasna-version.txt","$env:TEMP\jasna-version-err.txt" -ErrorAction SilentlyContinue) -join ' ').Trim() }
    } catch { $version = "failed: $_" }
    Note 'jasna_version' $version
    if ($version -notmatch '0\.10\.0') { Block "Jasna version must report 0.10.0; got '$version'" }

    $ffprobe = @((Join-Path (Split-Path -Parent $chosen.Path) 'ffprobe.exe'),
                 (Join-Path (Split-Path -Parent $chosen.Path) 'ffmpeg\bin\ffprobe.exe')) |
               Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $ffprobe) { $ffprobe = (Get-Command ffprobe.exe -ErrorAction SilentlyContinue).Source }
    Note 'ffprobe' ($(if ($ffprobe) { $ffprobe } else { 'NONE' }))
    if (-not $ffprobe) { Block 'no ffprobe.exe; output validation would fail after restoration' }
}

Write-Host '== python =='
$usable = $null
$seen = @()
# The probe carries no quotes of its own. The previous one embedded double
# quotes inside a string handed to a native executable, and Windows ate them:
# the interpreter received an unbalanced expression and answered with a
# SyntaxError, which this script then read as "not a usable interpreter" — on a
# machine where the interpreter was installed, correct, and three lines above.
$probeSource = 'import sys,platform;print(sys.version_info[0],sys.version_info[1],platform.machine())'
$roots = @("$env:SystemDrive\MosaicRuntime\python311\python.exe") +
         @(Get-Command python.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
foreach ($candidate in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $probe = & $candidate -c $probeSource 2>&1
    $text = (@($probe) -join ' ').Trim()
    $seen += "$candidate -> $text"
    Write-Host "  candidate              $candidate -> $text"
    $parts = $text.Split(' ')
    if ($parts.Count -eq 3 -and $parts[0] -eq '3' -and $parts[1] -in @('11','12') -and
        $parts[2] -eq 'AMD64' -and -not $usable) { $usable = $candidate }
}
Note 'python_candidates' ($(if ($seen.Count) { $seen -join ' | ' } else { 'none' }))
Note 'python_usable' ($(if ($usable) { $usable } else { 'NONE' }))
if (-not $usable) { Block 'no Python 3.11/3.12 AMD64; installing one inside the window is forbidden' }

Write-Host '== capacity =='
$volume = if ($chosen) { (Split-Path -Qualifier $chosen.Path) } else { 'C:' }
$free = [math]::Round(((Get-PSDrive -Name $volume.TrimEnd(':')).Free / 1GB), 1)
Note 'free_gb' "$free on $volume"
if ($free -lt $MinimumFreeGb) { Block "only ${free}GB free on $volume; need at least ${MinimumFreeGb}GB" }

Write-Host '== network =='
$transfer = 'unreachable'
try {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $head = & curl.exe -sS -I -L --connect-timeout 10 --max-time 25 -o NUL -w '%{http_code} %{size_download}' $BundleUrl 2>&1
    $timer.Stop()
    $transfer = "$head in $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
} catch { $transfer = "failed: $_" }
Note 'bundle_head' $transfer
if ($transfer -notmatch '^200') { Block 'the deployment bundle is not reachable from this machine' }

Write-Host '== leftovers =='
$previous = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'MosaicRestore') -Directory -ErrorAction SilentlyContinue)
Note 'previous_runs' ($(if ($previous.Count) { ($previous | Select-Object -ExpandProperty Name) -join ', ' } else { 'none' }))
$running = @(Get-Process cloudflared, jasna -ErrorAction SilentlyContinue)
Note 'running_processes' ($(if ($running.Count) { ($running | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ' } else { 'none' }))

$facts['elapsed_seconds'] = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$facts['blockers'] = $blockers
$facts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Report -Encoding UTF8

Write-Host ''
Write-Host "report: $Report  (elapsed $($facts['elapsed_seconds'])s)"
if ($blockers.Count) {
    Write-Host ''
    Write-Host "PREFLIGHT FAIL ($($blockers.Count) blocker(s)). STOP THE MACHINE NOW; do not deploy."
    $blockers | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host ''
Write-Host 'PREFLIGHT PASS. The machine carries what the deployment assumes; proceed to the bundle transfer.'
