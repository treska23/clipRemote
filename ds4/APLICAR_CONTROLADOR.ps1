$ErrorActionPreference = "Continue"

$Version = "2026.09.03-DIAG2"
$desktop = [Environment]::GetFolderPath("Desktop")
$work = Join-Path $env:TEMP ("DS4ClipDiag_" + [guid]::NewGuid().ToString("N"))
$report = Join-Path $work "DIAGNOSTICO_DS4_CLIPSTUDIO.txt"
$zip = Join-Path $desktop "PAQUETE_DIAGNOSTICO_DS4_CLIP.zip"
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Add([string]$s = "") { Add-Content -LiteralPath $report -Value $s -Encoding UTF8 }
function Redact([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $s = [regex]::Replace($s, '(?i)([0-9A-F]{2}[:-]){5}[0-9A-F]{2}', '<MAC>')
    return $s
}

"DIAGNOSTICO DS4WINDOWS + CLIP STUDIO" | Set-Content -LiteralPath $report -Encoding UTF8
Add ("Version diagnostico: " + $Version)
Add ("Fecha: " + (Get-Date))
Add ""

# DS4Windows process and config
Add "[1] DS4WINDOWS"
$procs = @(Get-Process DS4Windows -ErrorAction SilentlyContinue)
foreach($p in $procs){
    try {
        Add ("PID=" + $p.Id)
        Add ("Path=" + $p.Path)
        $v=(Get-Item $p.Path).VersionInfo
        Add ("FileVersion=" + $v.FileVersion)
    } catch {}
}
$ds4Root = Join-Path $env:APPDATA "DS4Windows"
foreach($name in @("Profiles.xml","ControllerConfigs.xml","Auto Profiles.xml")){
    $f=Join-Path $ds4Root $name
    if(Test-Path $f){
        Copy-Item $f (Join-Path $work $name) -Force
        Add ($name + "=" + $f)
    }
}
$profile=Join-Path $ds4Root "Profiles\ClipStudio_DualShock4.xml"
if(Test-Path $profile){
    Copy-Item $profile (Join-Path $work "ClipStudio_DualShock4.xml") -Force
    try {
        [xml]$x=Get-Content $profile -Raw -Encoding UTF8
        $n=$x.DS4Windows
        Add ("TouchpadOutputMode="+$n.TouchpadOutputMode)
        Add ("TouchpadButtonMode="+$n.TouchpadButtonMode)
        Add ("TouchpadClickPassthru="+$n.TouchpadClickPassthru)
        Add ("StartTouchpadOff="+$n.StartTouchpadOff)
        Add ("touchToggle="+$n.touchToggle)
        Add ("DpadLeft="+$n.Control.Key.DpadLeft)
        Add ("DpadRight="+$n.Control.Key.DpadRight)
    } catch {}
}
Add ""

# Detailed PnP / hardware IDs
Add "[2] MANDO - HARDWARE IDS"
try {
    $wc = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '(?i)Wireless Controller|DualShock|Game Controller' }
    foreach($d in $wc){
        Add ("FriendlyName="+$d.FriendlyName)
        Add ("InstanceId="+(Redact $d.InstanceId))
        foreach($key in @(
            'DEVPKEY_Device_HardwareIds',
            'DEVPKEY_Device_CompatibleIds',
            'DEVPKEY_Device_Parent',
            'DEVPKEY_Device_Manufacturer',
            'DEVPKEY_Device_BusReportedDeviceDesc',
            'DEVPKEY_Device_Service'
        )){
            try {
                $v=(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $key -ErrorAction Stop).Data
                if($v -is [array]){ $v=$v -join '; ' }
                Add ($key + "=" + (Redact ([string]$v)))
            } catch {}
        }
        Add ""
    }
} catch { Add ("ERROR PNP="+$_.Exception.Message) }

# Also record every Sony-like HID node so VID/PID can be seen
try {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '(?i)VID_054C|VID_0F0D|VID_057E|VID_054C&PID_' -or $_.FriendlyName -match '(?i)Wireless Controller' } |
        ForEach-Object { Add ((Redact $_.InstanceId) + " | " + $_.FriendlyName + " | " + $_.Status) }
} catch {}
Add ""

# Find CSP config
Add "[3] CLIP STUDIO"
$docs=[Environment]::GetFolderPath("MyDocuments")
$roots=@(
    (Join-Path $docs "CELSYS"),(Join-Path $docs "CELSYS_EN"),
    (Join-Path $env:APPDATA "CELSYS"),(Join-Path $env:APPDATA "CELSYS_EN"),
    (Join-Path $env:USERPROFILE "OneDrive\Documentos\CELSYS"),
    (Join-Path $env:USERPROFILE "OneDrive\Documents\CELSYS")
) | Select-Object -Unique
$khcs=@()
foreach($r in $roots){
    if($r -and (Test-Path $r)){
        $khcs += Get-ChildItem $r -Filter default.khc -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {$_.FullName -match '[\\/]Shortcut[\\/]default\.khc$'}
    }
}
$khc=$khcs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if($khc){
    Add ("default.khc="+$khc.FullName)
    Copy-Item $khc.FullName (Join-Path $work "default.khc") -Force
    $base=Split-Path (Split-Path $khc.FullName -Parent) -Parent
    $tool=Join-Path $base "Tool\EditImageTool.todb"
    if(Test-Path $tool){
        Add ("EditImageTool.todb="+$tool)
        Copy-Item $tool (Join-Path $work "EditImageTool.todb") -Force
    }

    $sqlite=Get-ChildItem (Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater") -Filter sqlite3.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if($sqlite){
        Add ("sqlite3.exe="+$sqlite.FullName)
        Add ""
        Add "SHORTCUTMENU - REVISION/BRUSH/CORRECTION/STABILIZATION/F2-F7"
        try {
            $sql="SELECT menucommand, COALESCE(shortcut,'NULL'), modifier FROM shortcutmenu WHERE lower(menucommand) LIKE '%revision%' OR lower(menucommand) LIKE '%stabil%' OR lower(menucommand) LIKE '%correct%' OR lower(menucommand) LIKE '%brush%' OR shortcut IN ('F2','F3','F4','F5','F6','F7') ORDER BY menucommand, shortcut;"
            $out=& $sqlite.FullName -separator '|' $khc.FullName $sql 2>&1 | Out-String
            Add $out.Trim()
        } catch { Add ("ERROR SQLite shortcuts="+$_.Exception.Message) }
        Add ""
        Add "SCHEMA shortcutmenu"
        try {
            $out=& $sqlite.FullName -separator '|' $khc.FullName "PRAGMA table_info(shortcutmenu);" 2>&1 | Out-String
            Add $out.Trim()
        } catch {}
    }
}
Add ""

# Collect likely DS4Windows logs if present
Add "[4] LOGS DS4WINDOWS"
foreach($dir in @($ds4Root, ($procs | ForEach-Object { try { Split-Path $_.Path -Parent } catch {} }))){
    if($dir -and (Test-Path $dir)){
        Get-ChildItem $dir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)log|debug' -and $_.Length -lt 2MB } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5 |
            ForEach-Object {
                Add ($_.FullName + " | " + $_.LastWriteTime + " | " + $_.Length)
                try { Copy-Item $_.FullName (Join-Path $work ("DS4LOG_"+$_.Name)) -Force } catch {}
            }
    }
}
Add ""
Add "FIN DEL DIAGNOSTICO"

if(Test-Path $zip){ Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force

Write-Host ""
Write-Host "DIAGNOSTICO COMPLETO CREADO." -ForegroundColor Green
Write-Host $zip -ForegroundColor Yellow
Write-Host ""
Write-Host "No se ha cambiado ningun perfil ni ningun atajo." -ForegroundColor Cyan
Write-Host "Arrastra PAQUETE_DIAGNOSTICO_DS4_CLIP.zip al chat." -ForegroundColor Cyan
