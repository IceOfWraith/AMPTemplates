# Installs Farming Simulator 19 into the instance directory.
# The product key is posted to the GIANTS download portal to obtain the download link, then the disc image
# is fetched and its payload unpacked.
#
# Nothing here needs elevation, which an AMP instance running as NETWORK SERVICE does not have:
#   - the disc image is parsed directly instead of mounted, as Mount-DiskImage needs a privilege it lacks
#   - the game's Inno Setup installer is unpacked with innoextract instead of executed, because the
#     installer aborts with "You must be logged in as an administrator" for a non-admin account
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
$INNOEXTRACT_URL = 'https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-windows.zip'
$INNOEXTRACT_SHA256 = '6989342C9B026A00A72A38F23B62A8E6A22CC5DE69805CF47D68AC2FEC993065'

# Streams to disk. Invoke-WebRequest -OutFile buffers the whole body in memory on Windows PowerShell,
# which is several gigabytes here. The GIANTS CDN also 403s any request without the portal as its referer.
function Save-Download([string]$url, [string]$path, [string]$referer) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = $UA
    if ($referer) { $req.Referer = $referer }
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 300000
    $resp = $req.GetResponse()
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($path)
    try { $in.CopyTo($out, 1MB) } finally { $out.Dispose(); $in.Dispose(); $resp.Close() }
}

# Extracts an ISO9660 image without mounting it. Files are stored as contiguous unencoded extents,
# so extraction is a seek and a copy. The disc is a hybrid ISO9660/UDF image and only the ISO9660
# side is read here, which is why names come back uppercased and mangled; Repair-SliceName fixes that.
function Expand-Iso9660([string]$IsoPath, [string]$Destination) {
    $SECTOR = 2048
    $fs = [IO.File]::OpenRead($IsoPath)
    try {
        $sec = New-Object byte[] $SECTOR
        [void]$fs.Seek(16 * $SECTOR, 'Begin')
        [void]$fs.Read($sec, 0, $SECTOR)
        if ([Text.Encoding]::ASCII.GetString($sec, 1, 5) -ne 'CD001') { throw 'the download is not an ISO9660 disc image' }

        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@{ Lba = [BitConverter]::ToUInt32($sec, 158); Size = [BitConverter]::ToUInt32($sec, 166); Path = '' })

        while ($queue.Count) {
            $dir = $queue.Dequeue()
            $dirBytes = New-Object byte[] $dir.Size
            [void]$fs.Seek([int64]$dir.Lba * $SECTOR, 'Begin')
            [void]$fs.Read($dirBytes, 0, $dir.Size)

            $p = 0
            while ($p -lt $dirBytes.Length) {
                $len = $dirBytes[$p]
                if ($len -eq 0) {
                    # Records never straddle a sector boundary; the rest of this sector is padding.
                    $p = [math]::Floor($p / $SECTOR) * $SECTOR + $SECTOR
                    continue
                }
                $lba   = [BitConverter]::ToUInt32($dirBytes, $p + 2)
                $size  = [BitConverter]::ToUInt32($dirBytes, $p + 10)
                $flags = $dirBytes[$p + 25]
                $fiLen = $dirBytes[$p + 32]
                $first = $dirBytes[$p + 33]
                $name  = [Text.Encoding]::ASCII.GetString($dirBytes, $p + 33, $fiLen)
                $p += $len

                # The first two records of every directory are "." and "..", a single 0x00/0x01 byte.
                if ($fiLen -eq 1 -and ($first -eq 0 -or $first -eq 1)) { continue }
                $name = ($name -split ';')[0].TrimEnd('.')
                if (-not $name) { continue }

                $target = if ($dir.Path) { Join-Path $dir.Path $name } else { $name }
                if ($flags -band 2) {
                    $queue.Enqueue(@{ Lba = $lba; Size = $size; Path = $target })
                    New-Item -ItemType Directory -Path (Join-Path $Destination $target) -Force | Out-Null
                }
                else {
                    $outPath = Join-Path $Destination $target
                    New-Item -ItemType Directory -Path (Split-Path $outPath -Parent) -Force | Out-Null
                    [void]$fs.Seek([int64]$lba * $SECTOR, 'Begin')
                    $out = [IO.File]::Create($outPath)
                    try {
                        $buf = New-Object byte[] (4MB)
                        $left = [int64]$size
                        while ($left -gt 0) {
                            $want = [math]::Min([int64]$buf.Length, $left)
                            $got = $fs.Read($buf, 0, $want)
                            if ($got -le 0) { break }
                            $out.Write($buf, 0, $got)
                            $left -= $got
                        }
                    }
                    finally { $out.Dispose() }
                }
            }
        }
    }
    finally { $fs.Dispose() }
}

# ISO9660 cannot store a hyphen, so the "Setup-1.bin" slices are written as "SETUP_1.BIN". The unpacker
# looks up slices by the name recorded in the installer header, so every plausible spelling is made
# available. Hardlinks cost no space and need no privilege.
function Repair-SliceName([string]$dir) {
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*_*.bin' -File -ErrorAction SilentlyContinue) {
        $candidates = @(
            ($f.Name -replace '_(\d+)\.bin$', '-$1.bin'),   # only the slice separator
            ($f.Name -replace '_', '-')                     # base names that themselves contained hyphens
        ) | Sort-Object -Unique | Where-Object { $_ -ne $f.Name }

        foreach ($c in $candidates) {
            $alt = Join-Path $dir $c
            if (Test-Path -LiteralPath $alt) { continue }
            try { New-Item -ItemType HardLink -Path $alt -Target $f.FullName -ErrorAction Stop | Out-Null }
            catch { Copy-Item -LiteralPath $f.FullName -Destination $alt -ErrorAction SilentlyContinue }
        }
    }
}

# Setup.exe on the disc image; the second name is what other Farming Simulator releases have used.
function Find-Installer([string]$dir) {
    foreach ($n in @('Setup.exe', 'FarmingSimulator2019.exe')) {
        $p = Get-ChildItem -LiteralPath $dir -Filter $n -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { return $p.FullName }
    }
    $p = Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return $p.FullName }
    return $null
}

function Get-InnoExtract([string]$dir) {
    $exe = Join-Path $dir 'innoextract.exe'
    if (Test-Path $exe) { return $exe }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir 'innoextract.zip'
    Save-Download $INNOEXTRACT_URL $zip
    # Computed in .NET rather than with Get-FileHash, which depends on module autoloading resolving correctly.
    $sha = [Security.Cryptography.SHA256]::Create()
    $zs = [IO.File]::OpenRead($zip)
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($zs)).Replace('-', '') }
    finally { $zs.Dispose(); $sha.Dispose() }
    if ($hash -ne $INNOEXTRACT_SHA256) { throw "the innoextract download did not match its expected checksum (got $hash)" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $found = Get-ChildItem -LiteralPath $dir -Filter 'innoextract.exe' -File -Recurse | Select-Object -First 1
    if (-not $found) { throw 'innoextract.exe was not found in its download' }
    return $found.FullName
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
    $DownloadURL = @($links | Where-Object { $_ -match 'FarmingSimulator2019.*\.img$' })[0]
    if (-not $DownloadURL) {
        Write-Output 'ERROR: That product key unlocks downloads, but no Farming Simulator 19 disc image was among them:'
        $links | ForEach-Object { Write-Output "         $_" }
        exit 1
    }
    Write-Output "Found $([IO.Path]::GetFileName(([Uri]$DownloadURL).AbsolutePath))"
}

New-Item -ItemType Directory -Path $GameDir -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$download = Join-Path $WorkDir 'fs19_download.img'
if (Test-Path $download) { Remove-Item $download -Force }

# ~5GB download, unpacked to ~5GB more, then ~10GB of game files. Fail now rather than after the download.
$freeGB = [math]::Round(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($GameDir))).AvailableFreeSpace / 1GB, 1)
if ($freeGB -lt 17) {
    Write-Output "ERROR: Only $freeGB GB is free on the instance drive, and installing Farming Simulator 19 needs about 17GB."
    exit 1
}

Write-Output 'Downloading Farming Simulator 19. This is a multi-gigabyte download and will take a while'
try { Save-Download $DownloadURL $download $PORTAL }
catch {
    Write-Output "ERROR: The download failed: $($_.Exception.Message)"
    Write-Output '       If this is a 403, the download link was rejected by the CDN. Clear the Download Link'
    Write-Output '       setting so the key is used to look up a fresh link automatically.'
    exit 1
}
Write-Output ("Downloaded {0:N2} GB" -f ((Get-Item $download).Length / 1GB))

$unpack = Join-Path $WorkDir 'fs19_unpack'
$staging = Join-Path $WorkDir 'fs19_staging'
$tools = Join-Path $WorkDir 'tools'
try {
    foreach ($d in @($unpack, $staging)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }

    Write-Output 'Reading the disc image'
    Expand-Iso9660 $download $unpack
    Repair-SliceName $unpack
    # Release the image before unpacking, so it does not sit beside both the payload and the game files.
    Remove-Item $download -Force -ErrorAction SilentlyContinue

    $setup = Find-Installer $unpack
    if (-not $setup -or -not (Test-Path $setup)) { throw 'the installer was not found in the disc image' }

    Write-Output 'Fetching innoextract'
    $innoextract = Get-InnoExtract $tools

    Write-Output 'Unpacking the game. This takes several minutes'
    $out = & $innoextract --extract --output-dir $staging --color=off --progress=no $setup 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | Select-Object -Last 15 | ForEach-Object { Write-Output "    $_" }
        throw "innoextract exited with code $LASTEXITCODE"
    }

    # innoextract lays the payload out under the installer's {app} constant.
    $appDir = Join-Path $staging 'app'
    if (-not (Test-Path $appDir)) { throw 'the unpacked payload has no app directory' }
    Write-Output 'Moving the game into place'
    Get-ChildItem -LiteralPath $appDir -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $GameDir -Force
    }
}
catch {
    Write-Output "ERROR: Installation failed because $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item $download -Force -ErrorAction SilentlyContinue
    foreach ($d in @($unpack, $staging)) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path $marker)) {
    Write-Output 'ERROR: The game was unpacked but no dedicated server was found in it.'
    exit 1
}
Write-Output ("Farming Simulator 19 {0} installed" -f (Get-Content (Join-Path $GameDir 'VERSION') -ErrorAction SilentlyContinue))
