param(
    [string]$Application = 'C:\Jasna\jasna.exe',
    [string]$Ffprobe = 'C:\Jasna\ffprobe.exe',
    [string]$CommandTemplate = '',
    [string]$Python = '',
    [string]$Token = '',
    [int]$Minutes = 25
)
$ErrorActionPreference = 'Stop'
$agent = $null
$relay = $null
try {
    if ($Minutes -lt 1 -or $Minutes -gt 25) { throw 'Session limit must be 1..25 minutes' }
    if (-not (Test-Path -LiteralPath $Application -PathType Leaf)) {
        # Several paid windows have left copies behind, so "exactly one or fail"
        # is the wrong rule: it turns a machine that HAS a usable runtime into a
        # deployment failure. Candidates are ranked by what actually matters -
        # an installation is only usable with its pinned weights AND a prebuilt
        # TensorRT engine, because compiling one inside a billed window is
        # forbidden. A tie is still refused rather than guessed at.
        $roots = @('C:\Jasna', 'D:\Jasna', "$env:USERPROFILE\Jasna", "$env:USERPROFILE\Desktop",
                   "$env:USERPROFILE\Downloads", "$env:ProgramData\Jasna")
        $found = @($roots | Where-Object { Test-Path $_ } | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter jasna.exe -File -Recurse -Depth 4 -ErrorAction SilentlyContinue
        } | Select-Object -ExpandProperty FullName -Unique)
        if ($found.Count -eq 0) { throw "No jasna.exe found under: $($roots -join ', ')" }
        $ranked = @($found | ForEach-Object {
            $weights = Join-Path (Split-Path -Parent $_) 'model_weights'
            [pscustomobject]@{
                Path = $_
                Score = (@(Test-Path -LiteralPath (Join-Path $weights 'lada_mosaic_detection_model_v4_fast.pt')),
                         @(Test-Path -LiteralPath (Join-Path $weights 'lada_mosaic_restoration_model_generic_v1.2.pth')),
                         @((Test-Path $weights) -and @(Get-ChildItem -LiteralPath $weights -Filter *.engine -File -ErrorAction SilentlyContinue).Count -gt 0)
                        ) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
            }
        } | Sort-Object -Property Score -Descending)
        $best = $ranked[0]
        if ($best.Score -eq 0) { throw "Found jasna.exe but none carries pinned weights or a TensorRT engine: $($found -join ', ')" }
        if ($ranked.Count -gt 1 -and $ranked[1].Score -eq $best.Score) {
            throw "Several equally complete Jasna runtimes; pass -Application explicitly: $(($ranked | Where-Object { $_.Score -eq $best.Score } | Select-Object -ExpandProperty Path) -join ', ')"
        }
        $Application = $best.Path
        Write-Host "Runtime: $Application (completeness $($best.Score)/3)"
    }
    $jasnaRoot = Split-Path -Parent $Application
    if (-not (Test-Path -LiteralPath $Ffprobe -PathType Leaf)) {
        # The provisioner installs ffprobe under MosaicRuntime, and its PATH entry
        # is not visible to a session that was already open when it ran.
        $Ffprobe = @("$jasnaRoot\ffprobe.exe", "$jasnaRoot\ffmpeg\bin\ffprobe.exe",
                     "$env:SystemDrive\MosaicRuntime\ffmpeg\bin\ffprobe.exe") |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $Ffprobe) { $Ffprobe = (Get-Command ffprobe.exe -ErrorAction SilentlyContinue).Source }
    }
    $detector = "$jasnaRoot\model_weights\lada_mosaic_detection_model_v4_fast.pt"
    $restorer = "$jasnaRoot\model_weights\lada_mosaic_restoration_model_generic_v1.2.pth"
    if (-not $CommandTemplate) {
        $CommandTemplate = "& {application} --input {input} --output {output} --device cuda:0 --fp16 --detection-model lada-yolo-v4 --restoration-model-name basicvsrpp --restoration-model-path '$restorer' --compile-basicvsrpp --max-clip-size 60 --temporal-overlap 8 --codec h264 --cq 18 --log-level info"
    }
    foreach ($path in @($Application, $Ffprobe, $detector, $restorer, "$PSScriptRoot\cloudflared.exe")) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing prerequisite: $path" }
    }
    if ((Get-FileHash "$PSScriptRoot\cloudflared.exe" -Algorithm SHA256).Hash.ToLower() -ne 'f096265ec2fcbe9bb6e2d64268db167ced3fcbb83d894bdb9e2fcdb26f2ea7e2') {
        throw 'cloudflared checksum mismatch'
    }
    # Resolving the interpreter by PATH alone has already failed twice offline:
    # the Microsoft Store stub answers Get-Command first on a clean Windows, and a
    # machine can carry an interpreter whose architecture the bundled wheels do
    # not match. Both produce a deployment failure inside a billed window for a
    # machine that actually has a usable Python. So an explicit path wins, and the
    # fallback inspects every candidate instead of trusting the first.
    #
    # The provisioned interpreter is listed before PATH, as the preflight does,
    # and the probe is the preflight's: no embedded quotes, because Windows drops
    # them on the way to a native executable. It runs with errors non-terminating,
    # because under 'Stop' the Store stub's stderr became a thrown error that ended
    # the whole deployment before the real interpreter was ever tried.
    $candidates = @()
    if ($Python) { $candidates += $Python }
    $candidates += "$env:SystemDrive\MosaicRuntime\python311\python.exe"
    $candidates += @(Get-Command python.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    $probeSource = 'import sys,platform;print(sys.version_info[0],sys.version_info[1],platform.machine())'
    $python = $null
    $abi = $null
    $rejected = @()
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $ErrorActionPreference = 'Continue'
        $probe = & $candidate -c $probeSource 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { $rejected += "${candidate}: not a working interpreter"; continue }
        $parts = (@($probe) -join ' ').Trim().Split(' ')
        if ($parts.Count -ne 3 -or $parts[0] -ne '3') { $rejected += "${candidate}: unreadable version probe"; continue }
        if ($parts[1] -notin @('11','12')) { $rejected += "${candidate}: Python 3.$($parts[1])"; continue }
        # The bundled wheels are win_amd64. An ARM64 interpreter would fail the
        # offline install several steps later with a far less obvious message.
        if ($parts[2] -ne 'AMD64') { $rejected += "${candidate}: $($parts[2]) architecture"; continue }
        $python = $candidate
        $abi = '3' + $parts[1]
        break
    }
    if (-not $python) {
        throw "No usable Python 3.11/3.12 AMD64 interpreter. Checked: $($rejected -join '; '). Do not install a runtime during the paid window"
    }
    Write-Host "Interpreter: $python (Python $abi AMD64)"
    $run = Join-Path $env:LOCALAPPDATA ("MosaicRestore\P5-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    & $python -m venv "$run\venv"
    if ($LASTEXITCODE -ne 0) { throw 'Virtual environment creation failed' }
    $python = "$run\venv\Scripts\python.exe"
    & $python -m pip install --no-index --find-links "$PSScriptRoot\wheels\$abi" pywinauto Pillow pywin32
    if ($LASTEXITCODE -ne 0) { throw 'Offline GUI dependency installation failed' }
    # A token generated here has to be carried back to the controlling machine,
    # and the only channel is a remote-desktop clipboard that has already proved
    # unreliable in this project. Letting the caller supply one it already holds
    # means only the relay URL travels back. A supplied token is still required to
    # be long enough to be worth having.
    if ($Token) {
        if ($Token.Length -lt 24) { throw 'A supplied token must be at least 24 characters' }
        $env:MOSAIC_P5_TOKEN = $Token
    } else {
        $tokenBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($tokenBytes)
        $rng.Dispose()
        $env:MOSAIC_P5_TOKEN = [Convert]::ToBase64String($tokenBytes)
    }
    $config = @{
        root="$run\jobs"; application_path=$Application; ffprobe_path=$Ffprobe
        command_template=$CommandTemplate; token_env='MOSAIC_P5_TOKEN'
        bind='127.0.0.1'; port=8765; hourly_cost_usd=2.31
        max_upload_bytes=268435456; realtime_factor=0.60; jasna_version='0.10.0'
        jasna_models=@($detector, $restorer)
        tensorrt_cache="$jasnaRoot\model_weights"
    } | ConvertTo-Json
    [IO.File]::WriteAllText("$run\agent.json", $config, (New-Object Text.UTF8Encoding $false))
    $agent = Start-Process $python -ArgumentList "`"$PSScriptRoot\windows_gui_agent.py`" --config `"$run\agent.json`"" -PassThru -RedirectStandardOutput "$run\agent.log" -RedirectStandardError "$run\agent-errors.log"
    $ready = $false
    for ($i=0; $i -lt 15; $i++) {
        if ($agent.HasExited) { throw "Agent exited; inspect $run\agent-errors.log" }
        try {
            $null = Invoke-WebRequest 'http://127.0.0.1:8765/v1/health' -Headers @{Authorization="Bearer $env:MOSAIC_P5_TOKEN"} -UseBasicParsing -TimeoutSec 2
            $ready=$true; break
        } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw 'Agent readiness timed out' }
    $relay = Start-Process "$PSScriptRoot\cloudflared.exe" -ArgumentList 'tunnel --no-autoupdate --url http://127.0.0.1:8765' -PassThru -RedirectStandardOutput "$run\relay.log" -RedirectStandardError "$run\relay-errors.log"
    $endpoint = $null
    for ($i=0; $i -lt 30; $i++) {
        if ($relay.HasExited) { throw 'Relay exited' }
        $log = Get-Content "$run\relay-errors.log" -Raw -ErrorAction SilentlyContinue
        if ($log -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $endpoint=$Matches[0]; break }
        Start-Sleep -Seconds 1
    }
    if (-not $endpoint) { throw 'Relay readiness timed out' }
    $connection = @{endpoint=$endpoint; token=$env:MOSAIC_P5_TOKEN; expires_utc=[DateTime]::UtcNow.AddMinutes($Minutes).ToString('o')}
    [IO.File]::WriteAllText("$run\connection.json", ($connection | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    $acl = Get-Acl "$run\connection.json"
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($env:USERNAME,'FullControl','Allow')))
    Set-Acl "$run\connection.json" $acl
    Write-Host "PASS P5 deployment: $endpoint"
    Write-Host "Connection file (secret, do not paste into chat): $run\connection.json"
    Write-Host 'Closing this window stops agent/relay only, NOT AirGPU billing. Always click Stop in AirGPU.'
    $deadline = [DateTime]::UtcNow.AddMinutes($Minutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($agent.HasExited -or $relay.HasExited) { throw 'Agent or relay disconnected: STOP AND SHUT DOWN AirGPU' }
        Start-Sleep -Seconds 2
    }
    Write-Host 'Session deadline reached: STOP AND SHUT DOWN AirGPU'
} catch {
    Write-Host "FAIL P5 deployment: $_; STOP AND SHUT DOWN AirGPU"
    exit 1
} finally {
    foreach ($process in @($relay,$agent)) {
        if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
    }
    Remove-Item Env:\MOSAIC_P5_TOKEN -ErrorAction SilentlyContinue
}
