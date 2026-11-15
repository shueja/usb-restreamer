$ErrorActionPreference = 'Stop'

$bundleDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $bundleDirectory 'config.json'
$mediaMtxPath = Join-Path $bundleDirectory 'mediamtx.exe'
$ffmpegPath = Join-Path $bundleDirectory 'ffmpeg.exe'
$mediaMtxLog = Join-Path $bundleDirectory 'mediamtx.log'
$ffmpegLog = Join-Path $bundleDirectory 'ffmpeg.log'

foreach ($requiredFile in @($configPath, $mediaMtxPath, $ffmpegPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required bundle file is missing: $requiredFile"
    }
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($config.camera_device)) {
    throw 'Set camera_device in config.json to the DirectShow name of your webcam.'
}
if ([string]::IsNullOrWhiteSpace($config.stream_path)) {
    throw 'Set stream_path in config.json to a non-empty RTSP path.'
}
if ($config.width -lt 1 -or $config.height -lt 1 -or $config.framerate -lt 1 -or $config.framerate -gt 120) {
    throw 'Set width, height, and framerate in config.json to valid values.'
}
if ($config.rtsp_port -lt 1 -or $config.rtsp_port -gt 65535) {
    throw 'Set rtsp_port in config.json to a valid TCP port.'
}
if ($config.stream_path -notmatch '^[A-Za-z0-9._/-]+$' -or $config.stream_path.StartsWith('/') -or $config.stream_path.Contains('..')) {
    throw 'stream_path in config.json may contain only letters, numbers, dots, underscores, hyphens, and slashes.'
}

function ConvertTo-QuotedArgument([string] $argument) {
    $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-BundleProcess([string] $filePath, [string[]] $arguments, [string] $stdoutPath, [string] $stderrPath) {
    $quotedArguments = @($arguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
    Start-Process -FilePath $filePath -ArgumentList $quotedArguments -WorkingDirectory $bundleDirectory `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
}

function Test-LocalRtspPort([int] $port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $port)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

$mediaMtxConfigPath = Join-Path $env:TEMP "usb-restreamer-$PID.yml"
$mediaMtxProcess = $null
$ffmpegProcess = $null

try {
    $quotedStreamPath = ConvertTo-Json -InputObject ([string]$config.stream_path) -Compress
    @"
logLevel: info
rtspTransports: [tcp]
rtspAddress: 0.0.0.0:$($config.rtsp_port)
authInternalUsers:
  - user: any
    pass:
    ips: []
    permissions:
      - action: publish
      - action: read
paths:
  ${quotedStreamPath}:
    source: publisher
"@ | Set-Content -LiteralPath $mediaMtxConfigPath -Encoding ascii

    $mediaMtxProcess = Start-BundleProcess $mediaMtxPath @($mediaMtxConfigPath) $mediaMtxLog "$mediaMtxLog.err"
    $serverReady = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ($mediaMtxProcess.HasExited) {
            throw "MediaMTX exited during startup. Check $mediaMtxLog and $mediaMtxLog.err."
        }
        if (Test-LocalRtspPort ([int]$config.rtsp_port)) {
            $serverReady = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $serverReady) {
        throw "MediaMTX did not open port $($config.rtsp_port). Check $mediaMtxLog and $mediaMtxLog.err."
    }

    $ffmpegArguments = @(
        '-hide_banner', '-f', 'dshow',
        '-framerate', [string]$config.framerate,
        '-video_size', "$($config.width)x$($config.height)"
    )
    if (-not [string]::IsNullOrWhiteSpace($config.pixel_format)) {
        $ffmpegArguments += @('-pixel_format', [string]$config.pixel_format)
    }
    $ffmpegArguments += @(
        '-i', "video=$($config.camera_device)",
        '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
        '-pix_fmt', 'yuv420p', '-f', 'rtsp', '-rtsp_transport', 'tcp',
        "rtsp://127.0.0.1:$($config.rtsp_port)/$($config.stream_path)"
    )
    $ffmpegProcess = Start-BundleProcess $ffmpegPath $ffmpegArguments $ffmpegLog "$ffmpegLog.err"

    Write-Host "Publishing to rtsp://<this-PC-LAN-address>:$($config.rtsp_port)/$($config.stream_path)"
    Write-Host "Logs: $mediaMtxLog and $ffmpegLog"
    try {
        $firewallProfiles = Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop
        if ($firewallProfiles | Where-Object { $_.Enabled }) {
            Write-Warning "Windows Firewall is enabled and may block inbound TCP port $($config.rtsp_port). This bundle does not change firewall settings."
        }
        else {
            Write-Host 'Windows Firewall profiles are disabled.'
        }
    }
    catch {
        Write-Warning "Could not check Windows Firewall status. If LAN clients cannot connect, ask your administrator about inbound TCP port $($config.rtsp_port)."
    }

    $lanAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress -Unique)
    foreach ($address in $lanAddresses) {
        Write-Host "RTSP URL: rtsp://${address}:$($config.rtsp_port)/$($config.stream_path)"
    }

    while ($true) {
        Start-Sleep -Seconds 1
        if ($mediaMtxProcess.HasExited) {
            throw "MediaMTX stopped. Check $mediaMtxLog and $mediaMtxLog.err."
        }
        if ($ffmpegProcess.HasExited) {
            throw "FFmpeg stopped. Check $ffmpegLog and $ffmpegLog.err."
        }
    }
}
finally {
    foreach ($process in @($ffmpegProcess, $mediaMtxProcess)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $mediaMtxConfigPath -Force -ErrorAction SilentlyContinue
}
