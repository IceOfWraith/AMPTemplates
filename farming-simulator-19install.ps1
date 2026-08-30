# Installs Farming Simulator 19 into the instance directory.
# The product key is posted to the GIANTS download portal to obtain the download link, then the full game
# disc image is fetched, mounted (or unpacked) and its Inno Setup installer run silently.
param(
    [string]$Key = '',
    [string]$DownloadURL = '',
    [Parameter(Mandatory=$true)][string]$GameDir,
    [Parameter(Mandatory=$true)][string]$WorkDir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# A path ending in a backslash escapes its own closing quote on the command line, gluing a quote onto the value.
function Clear-PathArg([string]$p) { if (-not $p) { return '' } $p.Trim().Trim('"').TrimEnd('\') }
$GameDir = Clear-PathArg $GameDir
$WorkDir = Clear-PathArg $WorkDir

$PORTAL = 'https://eshop.giants-software.com/downloads.php'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

# Streams to disk. Invoke-WebRequest -OutFile buffers the whole body in memory on Windows PowerShell,
# which is several gigabytes here. The CDN also 403s any request that does not carry the portal as its referer.
function Save-Download([string]$url, [string]$path) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = $UA
    $req.Referer = $PORTAL
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 300000
    $resp = $req.GetResponse()
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($path)
    try { $in.CopyTo($out, 1MB) } finally { $out.Dispose(); $in.Dispose(); $resp.Close() }
}

$marker = Join-Path $GameDir 'dedicatedServer.exe'
if (Test-Path $marker) {
    $v = (Get-Content (Join-Path $GameDir 'VERSION') -ErrorAction SilentlyContinue)
    Write-Output "Farming Simulator 19 $v already installed. Skipping"
    Write-Output 'Delete the game folder inside this instance to force a reinstall'
    exit 0
}

$Key = $Key.Trim()
$DownloadURL = $DownloadURL.Trim().Trim('"')

if (-not $DownloadURL) {
    if (-not $Key) {
        Write-Output 'ERROR: No product key is set, so the download link cannot be looked up.'
        Write-Output '       Set the Product Key setting on this instance, then update it again.'
        exit 1
    }
    Write-Output 'Looking up the download link from the GIANTS download portal...'
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $PORTAL -Method POST -UserAgent $UA `
            -Body @{ activationKey = $Key; foobar = 'DOWNLOAD' } -ErrorAction Stop
    }
    catch {
        Write-Output "ERROR: Could not reach the GIANTS download portal: $($_.Exception.Message)"
        exit 1
    }

    $links = @([regex]::Matches($resp.Content, 'https://cdn[0-9]*\.giants-software\.com/eshop/[^"]+') |
        ForEach-Object { $_.Value } | Sort-Object -Unique)
    if (-not $links.Count) {
        Write-Output 'ERROR: The download portal returned no downloads for that product key.'
        Write-Output '       Check the Product Key setting, or confirm the key at the portal in a browser.'
        exit 1
    }
    # Prefer the disc image; the zip holds the same installer and is the fallback.
    $DownloadURL = @($links | Where-Object { $_ -match 'FarmingSimulator2019.*\.img$' })[0]
    if (-not $DownloadURL) { $DownloadURL = @($links | Where-Object { $_ -match 'FarmingSimulator2019.*\.zip$' })[0] }
    if (-not $DownloadURL) {
        Write-Output 'ERROR: That product key unlocks downloads, but no Farming Simulator 19 Windows download was among them:'
        $links | ForEach-Object { Write-Output "         $_" }
        exit 1
    }
    Write-Output "Found $([IO.Path]::GetFileName(([Uri]$DownloadURL).AbsolutePath))"
}

New-Item -ItemType Directory -Path $GameDir -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# Keep the real extension; it decides whether this is a disc image or an archive.
$ext = [IO.Path]::GetExtension(([Uri]$DownloadURL).AbsolutePath)
if (-not $ext) { $ext = '.img' }
$download = Join-Path $WorkDir "fs19_download$ext"
if (Test-Path $download) { Remove-Item $download -Force }

Write-Output 'Downloading Farming Simulator 19. This is a multi-gigabyte download and will take a while'
try { Save-Download $DownloadURL $download }
catch {
    Write-Output "ERROR: The download failed: $($_.Exception.Message)"
    Write-Output '       If this is a 403, the download link was rejected by the CDN. Clear the Download Link'
    Write-Output '       setting so the key is used to look up a fresh link automatically.'
    exit 1
}
Write-Output ("Downloaded {0:N2} GB" -f ((Get-Item $download).Length / 1GB))

$mounted = $false
$setup = $null
try {
    if ($ext -in @('.zip')) {
        $unpack = Join-Path $WorkDir 'fs19_unpack'
        if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
        Expand-Archive -Path $download -DestinationPath $unpack -Force
        $setup = (Get-ChildItem $unpack -Filter 'Setup.exe' -Recurse -File | Select-Object -First 1).FullName
    }
    else {
        # Disc image: mount it and run the installer straight off the volume.
        $image = Mount-DiskImage -ImagePath $download -PassThru -ErrorAction Stop
        $mounted = $true
        $letter = ($image | Get-Volume).DriveLetter
        if (-not $letter) { throw 'the mounted image has no drive letter' }
        $setup = "${letter}:\Setup.exe"
    }

    if (-not $setup -or -not (Test-Path $setup)) { throw 'Setup.exe was not found in the download' }

    Write-Output 'Installing Farming Simulator 19. This takes several minutes'
    $log = Join-Path $WorkDir 'fs19_install.log'
    # Single argument string is passed through verbatim, which keeps paths containing spaces intact.
    $argLine = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /DIR="{0}" /LOG="{1}"' -f $GameDir, $log
    $proc = Start-Process -FilePath $setup -ArgumentList $argLine -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "the installer exited with code $($proc.ExitCode)" }
}
catch {
    Write-Output "ERROR: Installation failed because $($_.Exception.Message)"
    if ($mounted) { Dismount-DiskImage -ImagePath $download -ErrorAction SilentlyContinue | Out-Null }
    exit 1
}
finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $download -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item $download -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $WorkDir 'fs19_unpack') -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $marker)) {
    Write-Output 'ERROR: The installer finished but no dedicated server was installed.'
    exit 1
}
Write-Output ("Farming Simulator 19 {0} installed" -f (Get-Content (Join-Path $GameDir 'VERSION') -ErrorAction SilentlyContinue))
