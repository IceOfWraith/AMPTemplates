# Prepares the dedicated server before AMP starts it: writes dedicatedServer.xml from AMP settings and
# exposes the game's log directory inside the instance, since the game insists on logging under the user profile.
param(
    [Parameter(Mandatory=$true)][string]$GameDir,
    [Parameter(Mandatory=$true)][string]$InstanceLogDir,
    [int]$WebPort = 8080,
    [int]$TlsPort = 8443,
    [string]$EnableTLS = 'false',
    [string]$AdminUsername = 'admin',
    [string]$AdminPassword = ''
)
$ErrorActionPreference = 'Stop'

# The dedicated server hardcodes this profile folder; neither <game name> nor -name can move it.
$profileDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2019'
$logDir = Join-Path $profileDir 'dedicated_server\logs'
$serverLog = Join-Path $logDir 'server.log'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if (-not (Test-Path $serverLog)) { New-Item -ItemType File -Path $serverLog | Out-Null }

# AMP tails a path inside the instance, so link that to the profile's log directory.
$existing = Get-Item $InstanceLogDir -Force -ErrorAction SilentlyContinue
if ($existing -and -not $existing.LinkType) { Remove-Item $InstanceLogDir -Recurse -Force }
elseif ($existing -and ($existing.Target | Select-Object -First 1) -ne $logDir) { Remove-Item $InstanceLogDir -Force }
if (-not (Test-Path $InstanceLogDir)) {
    New-Item -ItemType Junction -Path $InstanceLogDir -Target $logDir | Out-Null
    Write-Output "Linked instance log directory to $logDir"
}

$xmlPath = Join-Path $GameDir 'dedicatedServer.xml'
if (-not (Test-Path $xmlPath)) {
    Write-Output "ERROR: Could not find $xmlPath"
    Write-Output '       Update this instance to install the game before starting it.'
    exit 1
}

$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($xmlPath)

$webserver = $xml.SelectSingleNode('/server/webserver')
$webserver.SetAttribute('port', $WebPort)

$tls = $xml.SelectSingleNode('/server/webserver/tls')
if ($tls) {
    $tls.SetAttribute('port', $TlsPort)
    $tls.SetAttribute('active', $(if ($EnableTLS -eq 'true') { 'true' } else { 'false' }))
}

$admin = $xml.SelectSingleNode('/server/webserver/initial_admin')
if ($admin) {
    $u = $admin.SelectSingleNode('username')
    if ($u) { $u.InnerText = $AdminUsername }
    if ($AdminPassword) {
        # The server rewrites <password> as <passphrase> on first run, so write the tag it settles on.
        $p = $admin.SelectSingleNode('passphrase')
        if (-not $p) {
            $p = $xml.CreateElement('passphrase')
            $old = $admin.SelectSingleNode('password')
            # Replace in place where possible so the file keeps its indentation.
            if ($old) { [void]$admin.ReplaceChild($p, $old) } else { [void]$admin.AppendChild($p) }
        }
        $p.InnerText = $AdminPassword
    }
}

$xml.Save($xmlPath)
Write-Output "Configured dedicated server on port $WebPort"
