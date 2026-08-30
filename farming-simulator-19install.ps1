# Installs Farming Simulator 19 into the instance directory from a download link supplied in AMP.
# The download is the full game ESD disc image, so it is mounted (or unpacked) and its Inno Setup installer run silently.
param(
    [string]$DownloadURL = '',
    [Parameter(Mandatory=$true)][string]$GameDir,
    [Parameter(Mandatory=$true)][string]$WorkDir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$marker = Join-Path $GameDir 'dedicatedServer.exe'
if (Test-Path $marker) {
    $v = (Get-Content (Join-Path $GameDir 'VERSION') -ErrorAction SilentlyContinue)
    Write-Output "Farming Simulator 19 $v already installed. Skipping"
    Write-Output 'Delete the game folder inside this instance to force a reinstall'
    exit 0
}

$DownloadURL = $DownloadURL.Trim()
if (-not $DownloadURL) {
    Write-Output 'ERROR: No download link is set.'
    Write-Output '       Sign in at https://my.farming-simulator.com/, right click the Farming Simulator 19 download,'
    Write-Output '       copy the link address into the Download Link setting, then update this instance.'
    exit 1
}

New-Item -ItemType Directory -Path $GameDir -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# Keep the real extension; it decides whether this is a disc image or an archive.
$ext = [IO.Path]::GetExtension(([Uri]$DownloadURL).AbsolutePath)
if (-not $ext) { $ext = '.img' }
$download = Join-Path $WorkDir "fs19_download$ext"
if (Test-Path $download) { Remove-Item $download -Force }

Write-Output 'Downloading Farming Simulator 19. This is a multi-gigabyte download and will take a while'
try { Invoke-WebRequest -UseBasicParsing -Uri $DownloadURL -OutFile $download -ErrorAction Stop }
catch {
    Write-Output "ERROR: The download failed: $($_.Exception.Message)"
    Write-Output '       Download links from the Farming Simulator site expire, so copy a fresh one and try again.'
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
