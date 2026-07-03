<#
    GUIbiont launcher (Windows).

      .\run.ps1            start GUIbiont (pulls latest image, picks a free
                           port, opens your browser)
      .\run.ps1 stop       stop a running GUIbiont

    The only prerequisite is Docker Desktop:
    https://www.docker.com/products/docker-desktop/
    Your experiment data lives in %USERPROFILE%\GUIbiont-data and survives updates.

    If Windows blocks the script, run once:
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#>

param([string]$Command = "start")

$ErrorActionPreference = "Stop"

$Image          = if ($env:GUIBIONT_IMAGE) { $env:GUIBIONT_IMAGE } else { "ghcr.io/pinheirogroup/guibiont:latest" }
$Container      = "guibiont"
$DefaultDataDir = Join-Path $HOME "GUIbiont-data"
$ConfigFile     = Join-Path $env:APPDATA "GUIbiont\data_dir"
$PortStart      = if ($env:GUIBIONT_PORT) { [int]$env:GUIBIONT_PORT } else { 8080 }
$PortEnd        = $PortStart + 100

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Fail($m) { Write-Host $m -ForegroundColor Red; exit 1 }

# Ask (once) where to keep experiment data, then remember the answer.
# Precedence: GUIBIONT_DATA env var > saved choice > interactive prompt > default.
function Resolve-DataDir {
    if ($env:GUIBIONT_DATA) { return $env:GUIBIONT_DATA }          # explicit override
    if (Test-Path $ConfigFile) { return (Get-Content $ConfigFile -Raw).Trim() }
    if ([Environment]::UserInteractive) {                          # first run, ask
        Write-Host "Where should GUIbiont store your experiment data?"
        $reply = Read-Host "  Press Enter for the default [$DefaultDataDir]`n  Folder"
        if ([string]::IsNullOrWhiteSpace($reply)) { $reply = $DefaultDataDir }
        New-Item -ItemType Directory -Force -Path (Split-Path $ConfigFile) | Out-Null
        Set-Content -Path $ConfigFile -Value $reply
        return $reply
    }
    return $DefaultDataDir                                         # non-interactive
}

# --- stop subcommand --------------------------------------------------------
if ($Command -eq "stop") {
    docker stop $Container 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "GUIbiont stopped." } else { Info "GUIbiont was not running." }
    exit 0
}

# --- config subcommand: forget the saved folder and ask again next run ------
if ($Command -eq "config") {
    if (Test-Path $ConfigFile) { Remove-Item $ConfigFile }
    Ok "Data-folder choice reset. You'll be asked again on the next run."
    exit 0
}

# --- 1. Docker present and running? ----------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Docker is not installed. Get Docker Desktop: https://www.docker.com/products/docker-desktop/"
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "Docker is installed but not running - please start Docker Desktop and try again."
}

# --- 2. First-run data folders ----------------------------------------------
$DataDir = Resolve-DataDir
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir "raw_data")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir "Clean_data") | Out-Null
Info "Data folder: $DataDir"

# --- 3. Already running? Just reopen it -------------------------------------
$existingPort = docker inspect --format '{{ (index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort }}' $Container 2>$null
if ($LASTEXITCODE -eq 0 -and $existingPort) {
    $url = "http://localhost:$existingPort"
    Ok "GUIbiont is already running at $url"
    Start-Process $url
    exit 0
}

# --- 4. Find a free host port -----------------------------------------------
function Test-PortInUse([int]$p) {
    try { return (Test-NetConnection -ComputerName 127.0.0.1 -Port $p -WarningAction SilentlyContinue).TcpTestSucceeded }
    catch { return $false }
}
$Port = $null
foreach ($p in $PortStart..$PortEnd) {
    if (-not (Test-PortInUse $p)) { $Port = $p; break }
}
if (-not $Port) { Fail "No free port found in $PortStart-$PortEnd." }
Info "Using port $Port"

# --- 5. Pull the latest image (also the update path) ------------------------
Info "Checking for updates..."
docker pull $Image 2>$null
if ($LASTEXITCODE -ne 0) {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        Info "   (registry unreachable - using the local copy of $Image)"
    } else {
        Fail "Couldn't pull $Image and no local copy is present. Check your connection, or build locally: docker build -t $Image ."
    }
}

# --- 6. Start the container --------------------------------------------------
docker rm -f $Container 2>$null | Out-Null
docker run -d --name $Container `
    -p "${Port}:8080" `
    -v "$(Join-Path $DataDir 'raw_data'):/app/raw_data" `
    -v "$(Join-Path $DataDir 'Clean_data'):/app/Clean_data" `
    $Image | Out-Null

# --- 7. Wait for readiness, then open the browser ---------------------------
$url = "http://localhost:$Port"
Info "Starting GUIbiont..."
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 *> $null
        $ready = $true; break
    } catch {
        $running = docker ps --format '{{.Names}}' | Select-String -Pattern "^$Container$"
        if (-not $running) {
            Write-Host "GUIbiont failed to start. Logs:" -ForegroundColor Red
            docker logs $Container 2>&1 | Select-Object -Last 20
            exit 1
        }
        Start-Sleep -Seconds 1
    }
}

Start-Process $url
Ok "GUIbiont running at $url"
Info "   Stop it with:  .\run.ps1 stop"
