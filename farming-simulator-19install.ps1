# Installs Farming Simulator 19 into the instance directory.
# The product key is posted to the GIANTS download portal to obtain the download link, then the full game
# disc image is fetched, unpacked and its Inno Setup installer run silently.
# Nothing here needs elevation: the disc image is parsed directly rather than mounted, because
# Mount-DiskImage requires a privilege the account running an AMP instance does not hold.
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

                # The first two records of every directory are "." and "..", identified by a single 0x00/0x01 byte.
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

# ISO9660 cannot store a hyphen, so Inno's "Setup-1.bin" slices are written as "SETUP_1.BIN". The installer
# asks for the hyphenated name and, under /SUPPRESSMSGBOXES, waits forever for a disk that never arrives.
# Hardlinks cost no space and need no privilege, so every plausible spelling is made available.
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

# Keep the real extension; it decides whether this is a disc image or an archive.
$ext = [IO.Path]::GetExtension(([Uri]$DownloadURL).AbsolutePath).ToLower()
if (-not $ext) { $ext = '.img' }
$download = Join-Path $WorkDir "fs19_download$ext"
if (Test-Path $download) { Remove-Item $download -Force }

# ~5GB download, unpacked to ~5GB more, installing to ~10GB. Fail now rather than after the download.
$freeGB = [math]::Round(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($GameDir))).AvailableFreeSpace / 1GB, 1)
if ($freeGB -lt 17) {
    Write-Output "ERROR: Only $freeGB GB is free on the instance drive, and installing Farming Simulator 19 needs about 17GB."
    exit 1
}

Write-Output 'Downloading Farming Simulator 19. This is a multi-gigabyte download and will take a while'
try { Save-Download $DownloadURL $download }
catch {
    Write-Output "ERROR: The download failed: $($_.Exception.Message)"
    Write-Output '       If this is a 403, the download link was rejected by the CDN. Clear the Download Link'
    Write-Output '       setting so the key is used to look up a fresh link automatically.'
    exit 1
}
Write-Output ("Downloaded {0:N2} GB" -f ((Get-Item $download).Length / 1GB))

$unpack = Join-Path $WorkDir 'fs19_unpack'
try {
    if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
    Write-Output 'Extracting the installer from the disc image'
    Expand-Iso9660 $download $unpack
    Repair-SliceName $unpack
    # Release the download before installing, so it does not sit beside both the unpacked copy and the install.
    Remove-Item $download -Force -ErrorAction SilentlyContinue

    $setup = Find-Installer $unpack
    if (-not $setup -or -not (Test-Path $setup)) { throw 'the installer was not found in the download' }

    Write-Output 'Installing Farming Simulator 19. This takes several minutes'
    $log = Join-Path $WorkDir 'fs19_install.log'
    # Single argument string is passed through verbatim, which keeps paths containing spaces intact.
    $argLine = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /DIR="{0}" /LOG="{1}"' -f $GameDir, $log
    $proc = Start-Process -FilePath $setup -ArgumentList $argLine -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "the installer exited with code $($proc.ExitCode)" }
}
catch {
    Write-Output "ERROR: Installation failed because $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item $download -Force -ErrorAction SilentlyContinue
    Remove-Item $unpack -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $marker)) {
    Write-Output 'ERROR: The installer finished but no dedicated server was installed.'
    exit 1
}
Write-Output ("Farming Simulator 19 {0} installed" -f (Get-Content (Join-Path $GameDir 'VERSION') -ErrorAction SilentlyContinue))
