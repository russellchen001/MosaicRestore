<#
Offline Windows deployment rehearsal.

WHAT THIS IS FOR
    The Windows half of this project is about 800 lines that had never executed
    on any Windows machine, because the development Mac has no PowerShell. Every
    paid AirGPU window so far has ended before reaching Jasna, in deployment or
    transfer. This script runs that deployment on any Windows machine so those
    defects are found for free instead of at US$2.31 an hour.

WHAT THIS IS NOT
    This is NOT evidence for either formal cloud product, and its output must
    never be recorded as such. It cannot touch NVIDIA, CUDA, TensorRT or Jasna:
    the application and ffprobe below are empty placeholder files that are never
    executed, and the agent's readiness check is deliberately not called. What it
    proves is narrower and entirely machine independent: that the bundle
    transfers and verifies, that the offline wheels install, that the agent
    process starts and authenticates, and that the relay publishes an endpoint.
    A defect found here is a defect on AirGPU too; a pass here says nothing about
    AirGPU's own machine state.
#>
param(
    [string]$Python = "$env:LOCALAPPDATA\Programs\Python\Python312-x64\python.exe",
    [string]$Repo = '',
    [string]$Zip = '',
    [int]$Minutes = 2
)

$ErrorActionPreference = 'Stop'
$BundleUrl = 'https://github.com/russellchen001/MosaicRestore/releases/download/jasna-cloud-offline-20261005/mosaic-jasna-airgpu-v0.10.0-v3.zip'
$BundleSha = '9578bdeb232683e1d20b2cc74e3130d5217c5b7ba211dbfe3bfd2c4d83f42030'

$script:failed = 0
function Step([string]$name, [scriptblock]$body) {
    try {
        $value = & $body
        Write-Host "PASS  $name"
        return $value
    } catch {
        Write-Host "FAIL  $name :: $_"
        $script:failed = 1
        throw
    }
}

$work = Join-Path $env:TEMP ('MosaicRehearsal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$script:job = $null

try {
    Step 'interpreter is Python 3.11/3.12 AMD64' {
        if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "not found: $Python" }
        $probe = & $Python -c 'import sys,platform; print(str(sys.version_info.major)+str(sys.version_info.minor)+" "+platform.machine())' 2>&1
        $parts = "$probe".Trim().Split(' ')
        if ($parts.Count -ne 2) { throw "unreadable probe: $probe" }
        if ($parts[0] -notin @('311','312')) { throw "Python $($parts[0])" }
        if ($parts[1] -ne 'AMD64') { throw "$($parts[1]) architecture; the bundled wheels are win_amd64" }
        Write-Host "      $Python -> Python $($parts[0]) $($parts[1])"
    }

    $archive = Step 'bundle present and checksum matches the published release' {
        $target = if ($Zip) { $Zip } else { Join-Path $work 'bundle.zip' }
        if (-not $Zip) {
            & curl.exe -fL --connect-timeout 15 --max-time 600 --retry 0 -sS -o $target $BundleUrl
            if ($LASTEXITCODE -ne 0) { throw 'bundle download failed' }
        }
        $hash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $BundleSha) { throw "checksum $hash" }
        Write-Host "      $target"
        $target
    }

    $deploy = Step 'bundle expands with every file the deployment needs' {
        $destination = Join-Path $work 'deploy'
        Expand-Archive -LiteralPath $archive -DestinationPath $destination
        foreach ($file in @('deploy_windows_agent.ps1','windows_gui_agent.py','cloudflared.exe','SHA256.json','wheels')) {
            if (-not (Test-Path -LiteralPath (Join-Path $destination $file))) { throw "missing $file" }
        }
        $destination
    }

    # The published bundle is a snapshot. When a repository checkout is reachable,
    # rehearse the CURRENT scripts instead, so a fix is exercised before it is
    # repackaged rather than after.
    if ($Repo) {
        Step 'repository scripts overlaid onto the extracted bundle' {
            foreach ($pair in @(@('adapters\deploy_windows_agent.ps1','deploy_windows_agent.ps1'),
                                @('adapters\windows_gui_agent.py','windows_gui_agent.py'))) {
                $source = Join-Path $Repo $pair[0]
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "missing $source" }
                Copy-Item -LiteralPath $source -Destination (Join-Path $deploy $pair[1]) -Force
            }
            Write-Host "      from $Repo"
        }
    }

    $placeholders = Step 'placeholder runtime tree created (never executed)' {
        $root = Join-Path $work 'FakeJasna'
        New-Item -ItemType Directory -Path (Join-Path $root 'model_weights') -Force | Out-Null
        foreach ($leaf in @('jasna.exe','ffprobe.exe',
                            'model_weights\lada_mosaic_detection_model_v4_fast.pt',
                            'model_weights\lada_mosaic_restoration_model_generic_v1.2.pth',
                            'model_weights\basicvsrpp_t4_fp16.engine')) {
            Set-Content -LiteralPath (Join-Path $root $leaf) -Value 'placeholder' -Encoding Ascii
        }
        $root
    }

    Step 'deployment reaches a published relay endpoint' {
        $script = Join-Path $deploy 'deploy_windows_agent.ps1'
        $script:job = Start-Job -ScriptBlock {
            param($file, $app, $probe, $python, $minutes)
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $file `
                -Application $app -Ffprobe $probe -Python $python -Minutes $minutes 2>&1
        } -ArgumentList $script,
                        (Join-Path $placeholders 'jasna.exe'),
                        (Join-Path $placeholders 'ffprobe.exe'),
                        $Python,
                        $Minutes
        $deadline = (Get-Date).AddSeconds(240)
        $seen = @()
        while ((Get-Date) -lt $deadline) {
            $seen += (Receive-Job $script:job)
            $text = ($seen -join "`n")
            if ($text -match 'PASS P5 deployment: (\S+)') {
                Write-Host "      endpoint $($Matches[1])"
                return
            }
            if ($text -match 'FAIL P5 deployment: (.+)') { throw $Matches[1] }
            if ($script:job.State -eq 'Completed') { throw "deployment ended without a verdict:`n$text" }
            Start-Sleep -Seconds 2
        }
        throw "no verdict within 240 seconds:`n$($seen -join "`n")"
    }
} catch {
    # Step already reported the failing stage; this keeps the summary single-voiced.
} finally {
    if ($null -ne $script:job) {
        if ($script:job.State -eq 'Running') { Stop-Job $script:job -ErrorAction SilentlyContinue }
        Remove-Job $script:job -Force -ErrorAction SilentlyContinue
    }
    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed) {
    Write-Host ''
    Write-Host 'REHEARSAL FAILED. Fix this on the free machine; do not open a paid window.'
    exit 1
}
Write-Host ''
Write-Host 'REHEARSAL PASSED (deployment chain only; NOT cloud product evidence).'
