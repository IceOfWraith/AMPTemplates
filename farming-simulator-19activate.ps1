# Activates Farming Simulator 19 by driving the launcher's product key dialog with a key supplied from AMP.
# The game offers no command line, config file or offline path for the key, so the MFC dialog is the only route.
# Idempotent: activation is a single 28-byte file per Windows account, so this exits immediately once it exists.
param(
    [string]$Key = '',
    [Parameter(Mandatory=$true)][string]$GameDir,
    [int]$DialogTimeoutSeconds = 60,
    [int]$ActivationTimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class FSWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    public static string Cls(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
    public static string Txt(IntPtr h){ var s=new StringBuilder(4096); GetWindowText(h,s,4096); return s.ToString(); }
    // GetWindowText returns "" for a caption-less control in another process; WM_GETTEXT works cross-process.
    public static string CtlTxt(IntPtr h){ var s=new StringBuilder(4096); SendMessage(h, 0x000D, (IntPtr)4096, s); return s.ToString(); }

    public static List<IntPtr> Dialogs(int pid){
        var r = new List<IntPtr>();
        EnumWindows((h,l)=>{ int p; GetWindowThreadProcessId(h, out p); if(p==pid && Cls(h)=="#32770") r.Add(h); return true; }, IntPtr.Zero);
        return r;
    }
    public static List<IntPtr> Kids(IntPtr parent){
        var r = new List<IntPtr>();
        EnumChildWindows(parent, (h,l)=>{ r.Add(h); return true; }, IntPtr.Zero);
        return r;
    }
}
'@

$WM_SETTEXT = 0x000C
$BM_CLICK   = 0x00F5
$ID_KEYEDIT = 1001   # Edit control in the product key dialog
$ID_ACTIVATE = 1     # "Activate >" button (IDOK)

# The game hardcodes this profile folder; neither the dedicated server config nor -name can move it.
$profileDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2019'
$activationFile = Join-Path $profileDir 'AHC_63805.dat'

function Stop-GameProcesses($launcher) {
    try { if ($launcher -and -not $launcher.HasExited) { $launcher.Kill() } } catch { }
    Get-Process -Name 'FarmingSimulator2019Game' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

if (Test-Path $activationFile) {
    Write-Output 'Farming Simulator 19 is already activated for this Windows account'
    exit 0
}

$Key = $Key.Trim()
if (-not $Key) {
    Write-Output 'ERROR: Farming Simulator 19 is not activated for this Windows account and no product key is set.'
    Write-Output '       Set the Product Key setting on this instance, then start it again.'
    exit 1
}

$launcherExe = Join-Path $GameDir 'FarmingSimulator2019.exe'
if (-not (Test-Path $launcherExe)) {
    Write-Output "ERROR: Could not find $launcherExe"
    Write-Output '       Update this instance to install the game before starting it.'
    exit 1
}

Write-Output 'Activating Farming Simulator 19...'
$proc = Start-Process -FilePath $launcherExe -WorkingDirectory $GameDir -PassThru

# Identify the key dialog by the presence of its edit control, not its caption, which is localised.
$dlg = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($DialogTimeoutSeconds)
while ((Get-Date) -lt $deadline -and $dlg -eq [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    foreach ($h in [FSWin]::Dialogs($proc.Id)) {
        if ([FSWin]::GetDlgItem($h, $ID_KEYEDIT) -ne [IntPtr]::Zero) { $dlg = $h; break }
    }
}

if ($dlg -eq [IntPtr]::Zero) {
    Stop-GameProcesses $proc
    if (Test-Path $activationFile) { Write-Output 'Farming Simulator 19 is already activated for this Windows account'; exit 0 }
    Write-Output 'ERROR: The product key dialog did not appear. Activation could not be completed.'
    exit 1
}

$edit = [FSWin]::GetDlgItem($dlg, $ID_KEYEDIT)
$btn  = [FSWin]::GetDlgItem($dlg, $ID_ACTIVATE)
[void][FSWin]::SendMessage($edit, $WM_SETTEXT, [IntPtr]::Zero, $Key)

if ([FSWin]::CtlTxt($edit) -ne $Key) {
    Stop-GameProcesses $proc
    Write-Output 'ERROR: Could not enter the product key into the activation dialog.'
    exit 1
}

[void][FSWin]::PostMessage($btn, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)

# The launcher reports the outcome in a second dialog; its static text is the authoritative result.
$resultHwnd = [IntPtr]::Zero
$resultText = ''
$deadline = (Get-Date).AddSeconds($ActivationTimeoutSeconds)
while ((Get-Date) -lt $deadline -and -not $resultText) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    foreach ($h in [FSWin]::Dialogs($proc.Id)) {
        if ($h -eq $dlg) { continue }
        $parts = @()
        foreach ($k in [FSWin]::Kids($h)) {
            if ([FSWin]::Cls($k) -ne 'Static') { continue }
            $t = [FSWin]::Txt($k); if (-not $t) { $t = [FSWin]::CtlTxt($k) }
            if ($t) { $parts += $t }
        }
        if ($parts.Count) { $resultHwnd = $h; $resultText = ($parts -join ' '); break }
    }
}

if ($resultHwnd -ne [IntPtr]::Zero) {
    $ok = [FSWin]::GetDlgItem($resultHwnd, $ID_ACTIVATE)
    if ($ok -ne [IntPtr]::Zero) { [void][FSWin]::PostMessage($ok, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) }
}

Start-Sleep -Seconds 3
# The launcher starts the game itself once activation succeeds, which is not what we want here.
Stop-GameProcesses $proc

if (Test-Path $activationFile) {
    Write-Output "Activation successful: $resultText"
    exit 0
}

if ($resultText) { Write-Output "ERROR: $resultText" }
else { Write-Output 'ERROR: Activation did not complete and the launcher reported no result.' }
exit 1
