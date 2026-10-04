param(
    [string]$Application = 'C:\Jasna\jasna.exe',
    [string]$Ffprobe = 'C:\Jasna\ffprobe.exe',
    [string]$CommandTemplate = '',
    [int]$Minutes = 25
)
$ErrorActionPreference = 'Stop'
$agent = $null
$relay = $null
try {
    if ($Minutes -lt 1 -or $Minutes -gt 25) { throw 'Session limit must be 1..25 minutes' }
    if (-not (Test-Path -LiteralPath $Application -PathType Leaf)) {
        $roots = @('C:\Jasna', "$env:USERPROFILE\Jasna", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads")
        $found = @($roots | Where-Object { Test-Path $_ } | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter jasna.exe -File -Recurse -Depth 4 -ErrorAction SilentlyContinue
        } | Select-Object -ExpandProperty FullName -Unique)
        if ($found.Count -ne 1) { throw "Expected exactly one existing Jasna runtime, found $($found.Count)" }
        $Application = $found[0]
    }
    $jasnaRoot = Split-Path -Parent $Application
    if (-not (Test-Path -LiteralPath $Ffprobe -PathType Leaf)) {
        $Ffprobe = @("$jasnaRoot\ffprobe.exe", "$jasnaRoot\ffmpeg\bin\ffprobe.exe") |
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
    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $abi = & $python -c 'import sys; print(str(sys.version_info.major)+str(sys.version_info.minor))'
    if ($LASTEXITCODE -ne 0 -or $abi -notin @('311','312')) { throw 'Existing Python 3.11 or 3.12 required; do not install a runtime during the paid window' }
    $run = Join-Path $env:LOCALAPPDATA ("MosaicRestore\P5-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    & $python -m venv "$run\venv"
    if ($LASTEXITCODE -ne 0) { throw 'Virtual environment creation failed' }
    $python = "$run\venv\Scripts\python.exe"
    & $python -m pip install --no-index --find-links "$PSScriptRoot\wheels\$abi" pywinauto Pillow pywin32
    if ($LASTEXITCODE -ne 0) { throw 'Offline GUI dependency installation failed' }
    $tokenBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($tokenBytes)
    $rng.Dispose()
    $env:MOSAIC_P5_TOKEN = [Convert]::ToBase64String($tokenBytes)
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
