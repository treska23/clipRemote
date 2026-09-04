$ErrorActionPreference = "Stop"

$Version = "2026.09.04-FIX7"
$RawBase = "https://raw.githubusercontent.com/treska23/clipRemote/main/ds4"
$ProfileUrl = "$RawBase/ClipStudio_DualShock4.xml"
$ProfileName = "ClipStudio_DualShock4"
$ds4Root = Join-Path $env:APPDATA "DS4Windows"
$profilesDir = Join-Path $ds4Root "Profiles"
$logDir = Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir ("update_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")

function Log([string]$s="") { Add-Content -LiteralPath $log -Value $s -Encoding UTF8 }
function Fail([string]$s) {
    Log ("ERROR: " + $s)
    Write-Host ""
    Write-Host ("ERROR: " + $s) -ForegroundColor Red
    Write-Host ("Log: " + $log)
    exit 1
}
function Download([string]$url,[string]$out) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    }
    catch {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if(-not $curl){ throw }
        & $curl.Source -L --fail --output $out $url
        if($LASTEXITCODE -ne 0){ throw "No se pudo descargar $url" }
    }
}
function Sql([string]$exe,[string]$db,[string]$query) {
    $r = & $exe $db $query 2>&1 | Out-String
    if($LASTEXITCODE -ne 0){ throw $r }
    return $r.Trim()
}
function Find-Csp {
    $docs=[Environment]::GetFolderPath("MyDocuments")
    $roots=@(
        (Join-Path $docs "CELSYS"),(Join-Path $docs "CELSYS_EN"),
        (Join-Path $env:APPDATA "CELSYS"),(Join-Path $env:APPDATA "CELSYS_EN"),
        (Join-Path $env:USERPROFILE "OneDrive\Documentos\CELSYS"),
        (Join-Path $env:USERPROFILE "OneDrive\Documents\CELSYS"),
        (Join-Path $env:USERPROFILE "OneDrive\Documentos\CELSYS_EN"),
        (Join-Path $env:USERPROFILE "OneDrive\Documents\CELSYS_EN")
    ) | Select-Object -Unique
    $all=@()
    foreach($r in $roots){
        if($r -and (Test-Path -LiteralPath $r)){
            $all += Get-ChildItem -LiteralPath $r -Filter default.khc -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {$_.FullName -match '[\\/]Shortcut[\\/]default\.khc$'}
        }
    }
    foreach($db in @($all | Sort-Object LastWriteTime -Descending -Unique)){
        $base=Split-Path (Split-Path $db.FullName -Parent) -Parent
        $tool=Join-Path $base "Tool\EditImageTool.todb"
        if(Test-Path -LiteralPath $tool){
            return [pscustomobject]@{Base=$base;ShortcutDb=$db.FullName;ToolDb=$tool}
        }
    }
    return $null
}
function Get-ControllerMac {
    try {
        $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -match '(?i)^Wireless Controller$|DualShock' } |
            Select-Object -First 1
        if($d -and $d.InstanceId -match '(?i)DEV_([0-9A-F]{12})'){
            $hex=$Matches[1].ToUpper()
            $parts=[regex]::Matches($hex,'..') | ForEach-Object {$_.Value}
            return ($parts -join ':')
        }
    } catch {}

    $logsDir=Join-Path $ds4Root "Logs"
    if(Test-Path -LiteralPath $logsDir){
        $logs=Get-ChildItem -LiteralPath $logsDir -Filter "ds4windows_log*.txt" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach($f in $logs){
            $txt=Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            $matches=[regex]::Matches($txt,'Found Controller:\s*([0-9A-F]{2}(?::[0-9A-F]{2}){5})\s*\(BT\)\s*\(DS4', 'IgnoreCase')
            if($matches.Count -gt 0){ return $matches[$matches.Count-1].Groups[1].Value.ToUpper() }
        }
    }
    return $null
}
function Save-XmlUtf8([xml]$xml,[string]$path) {
    $settings=New-Object System.Xml.XmlWriterSettings
    $settings.Indent=$true
    $settings.Encoding=New-Object System.Text.UTF8Encoding($false)
    $writer=[System.Xml.XmlWriter]::Create($path,$settings)
    try { $xml.Save($writer) } finally { $writer.Close() }
}

"CLIP STUDIO + DUALSHOCK 4 - $Version" | Set-Content -LiteralPath $log -Encoding UTF8
Log ("Fecha: " + (Get-Date))

if(Get-Process CLIPStudioPaint -ErrorAction SilentlyContinue){
    Fail "Cierra CLIP STUDIO PAINT antes de actualizar el mando."
}

$csp=Find-Csp
if(-not $csp){ Fail "No encuentro la configuracion de Clip Studio." }
$sqlite=Get-ChildItem (Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater") -Filter sqlite3.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not $sqlite){ Fail "No encuentro sqlite3.exe del actualizador." }

$mac=Get-ControllerMac
if(-not $mac){ Fail "No puedo obtener la direccion del DualShock. Dejalo conectado por Bluetooth y vuelve a ejecutar." }
Log ("Mando detectado: " + $mac)

# Capture DS4Windows executable before stopping it.
$ds4=@(Get-Process DS4Windows -ErrorAction SilentlyContinue)
$ds4Exe=$null
if($ds4.Count -gt 0){ try{$ds4Exe=$ds4[0].Path}catch{} }

# Backups
$stamp=Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir=Join-Path $csp.Base "DS4Controller_Backups"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$khcBackup=Join-Path $backupDir ("default_"+$stamp+".khc")
$toolBackup=Join-Path $backupDir ("EditImageTool_"+$stamp+".todb")
Copy-Item -LiteralPath $csp.ShortcutDb -Destination $khcBackup -Force
Copy-Item -LiteralPath $csp.ToolDb -Destination $toolBackup -Force

$ds4Backup=Join-Path $logDir ("ds4_backup_"+$stamp)
New-Item -ItemType Directory -Path $ds4Backup -Force | Out-Null
foreach($name in @("ControllerConfigs.xml","LinkedProfiles.xml")){
    $f=Join-Path $ds4Root $name
    if(Test-Path -LiteralPath $f){ Copy-Item -LiteralPath $f -Destination (Join-Path $ds4Backup $name) -Force }
}
$oldProfile=Join-Path $profilesDir ($ProfileName+".xml")
if(Test-Path -LiteralPath $oldProfile){ Copy-Item -LiteralPath $oldProfile -Destination (Join-Path $ds4Backup ($ProfileName+".xml")) -Force }
Log ("Backups CSP: " + $backupDir)
Log ("Backups DS4: " + $ds4Backup)

# --- CLIP STUDIO -------------------------------------------------------
try {
    if((Sql $sqlite.FullName $csp.ShortcutDb "PRAGMA integrity_check;") -ne "ok"){ throw "default.khc no pasa integrity_check antes de cambiarlo." }

    # Stabilization: square/triangle use dedicated F2/F3 bridge keys.
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='NULL' WHERE modifier=0 AND shortcut IN ('F2','F3') AND menucommand NOT IN ('toolflickerreductionminus','toolflickerreductionplus');" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='NULL', modifier=0 WHERE menucommand IN ('toolbrushrevisionminus','toolbrushrevisionplus');" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='F2', modifier=0 WHERE menucommand='toolflickerreductionminus';" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='F3', modifier=0 WHERE menucommand='toolflickerreductionplus';" | Out-Null

    # Selection bridge keys: F4=select all, F7=deselect, F6=clear selected.
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='NULL' WHERE modifier=0 AND shortcut IN ('F4','F6','F7') AND menucommand NOT IN ('selectall','selectdeselect','clear');" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "DELETE FROM shortcutmenu WHERE menucommand='selectall' AND shortcut='F4' AND modifier=0;" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "DELETE FROM shortcutmenu WHERE menucommand='selectdeselect' AND shortcut='F7' AND modifier=0;" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "DELETE FROM shortcutmenu WHERE menucommand='clear' AND shortcut='F6' AND modifier=0;" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "INSERT INTO shortcutmenu(menucommandtype,menucommand,shortcut,modifier) VALUES('basiccommand','selectall','F4',0);" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "INSERT INTO shortcutmenu(menucommandtype,menucommand,shortcut,modifier) VALUES('basiccommand','selectdeselect','F7',0);" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "INSERT INTO shortcutmenu(menucommandtype,menucommand,shortcut,modifier) VALUES('basiccommand','clear','F6',0);" | Out-Null

    # Zoom: X/Circle emit F8/F9.
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='NULL' WHERE modifier=0 AND shortcut IN ('F8','F9') AND menucommand NOT IN ('viewzoomout','viewzoomin');" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='F8', modifier=0 WHERE menucommand='viewzoomout';" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='F9', modifier=0 WHERE menucommand='viewzoomin';" | Out-Null

    # Undo/redo: preserve Ctrl+Z / Ctrl+Y and add dedicated F10/F11 rows.
    Sql $sqlite.FullName $csp.ShortcutDb "UPDATE shortcutmenu SET shortcut='NULL' WHERE modifier=0 AND shortcut IN ('F10','F11') AND menucommand NOT IN ('undo','redo');" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "DELETE FROM shortcutmenu WHERE menucommand='undo' AND shortcut='F10' AND modifier=0;" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "DELETE FROM shortcutmenu WHERE menucommand='redo' AND shortcut='F11' AND modifier=0;" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "INSERT INTO shortcutmenu(menucommandtype,menucommand,shortcut,modifier) VALUES('basiccommand','undo','F10',0);" | Out-Null
    Sql $sqlite.FullName $csp.ShortcutDb "INSERT INTO shortcutmenu(menucommandtype,menucommand,shortcut,modifier) VALUES('basiccommand','redo','F11',0);" | Out-Null

    $minus=Sql $sqlite.FullName $csp.ShortcutDb "SELECT shortcut||'|'||modifier FROM shortcutmenu WHERE menucommand='toolflickerreductionminus';"
    $plus=Sql $sqlite.FullName $csp.ShortcutDb "SELECT shortcut||'|'||modifier FROM shortcutmenu WHERE menucommand='toolflickerreductionplus';"
    $selectAllCount=[int](Sql $sqlite.FullName $csp.ShortcutDb "SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='selectall' AND shortcut='F4' AND modifier=0;")
    $deselectCount=[int](Sql $sqlite.FullName $csp.ShortcutDb "SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='selectdeselect' AND shortcut='F7' AND modifier=0;")
    $clearCount=[int](Sql $sqlite.FullName $csp.ShortcutDb "SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='clear' AND shortcut='F6' AND modifier=0;")
    $undoCount=[int](Sql $sqlite.FullName $csp.ShortcutDb "SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='undo' AND shortcut='F10' AND modifier=0;")
    $redoCount=[int](Sql $sqlite.FullName $csp.ShortcutDb "SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='redo' AND shortcut='F11' AND modifier=0;")
    if($minus -ne "F2|0" -or $plus -ne "F3|0"){ throw "No se pudo verificar la asignacion de estabilizacion." }
    if($selectAllCount -lt 1 -or $deselectCount -lt 1 -or $clearCount -lt 1){ throw "No se pudo verificar seleccionar/deseleccionar/borrar seleccion." }
    if($undoCount -lt 1 -or $redoCount -lt 1){ throw "No se pudo verificar deshacer/rehacer." }

    # Keep the exact requested pencil shortcut available on F5.
    $safe="Lápiz más oscuro".Replace("'","''")
    $n=[int](Sql $sqlite.FullName $csp.ToolDb ("SELECT COUNT(*) FROM Node WHERE NodeName='"+$safe+"';"))
    if($n -gt 0){
        Sql $sqlite.FullName $csp.ToolDb ("UPDATE Node SET NodeShortCutKey=0 WHERE NodeShortCutKey=41 AND NodeName<>'"+$safe+"';") | Out-Null
        Sql $sqlite.FullName $csp.ToolDb ("UPDATE Node SET NodeShortCutKey=41 WHERE NodeName='"+$safe+"';") | Out-Null
    }

    if((Sql $sqlite.FullName $csp.ShortcutDb "PRAGMA integrity_check;") -ne "ok"){ throw "default.khc no pasa integrity_check despues del cambio." }
    Log "Estabilizacion CSP: F2=menos; F3=mas"
    Log "Seleccion CSP: F4=seleccionar todo; F7=deseleccionar; F6=borrar seleccion"
    Log "Zoom CSP: F8=alejar; F9=acercar"
    Log "Historial CSP: F10=deshacer; F11=rehacer"
}
catch {
    Copy-Item -LiteralPath $khcBackup -Destination $csp.ShortcutDb -Force
    Copy-Item -LiteralPath $toolBackup -Destination $csp.ToolDb -Force
    Fail ("Error modificando Clip Studio; se restauro el backup. " + $_.Exception.Message)
}

# Stop DS4Windows before changing its device-specific config, otherwise it can
# overwrite the files on exit.
if($ds4.Count -gt 0){
    $ds4 | Stop-Process -Force
    Start-Sleep -Milliseconds 900
}
New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null

# Install latest controller profile.
$tempProfile=Join-Path $env:TEMP ($ProfileName+"_"+[guid]::NewGuid().ToString("N")+".xml")
Download $ProfileUrl $tempProfile
try { [xml](Get-Content -LiteralPath $tempProfile -Raw -Encoding UTF8) | Out-Null } catch { Fail "El perfil remoto no es XML valido." }
Copy-Item -LiteralPath $tempProfile -Destination (Join-Path $profilesDir ($ProfileName+".xml")) -Force
Remove-Item -LiteralPath $tempProfile -Force -ErrorAction SilentlyContinue

# --- DS4 Copycat -------------------------------------------------------
$ccPath=Join-Path $ds4Root "ControllerConfigs.xml"
if(Test-Path -LiteralPath $ccPath){
    [xml]$cc=Get-Content -LiteralPath $ccPath -Raw -Encoding UTF8
} else {
    [xml]$cc='<?xml version="1.0" encoding="utf-8"?><Controllers />'
}
$ccRoot=$cc.SelectSingleNode('/Controllers')
if(-not $ccRoot){ Fail "ControllerConfigs.xml no tiene el formato esperado." }
$controller=$ccRoot.SelectSingleNode("Controller[@Mac='$mac']")
if(-not $controller){
    $controller=$cc.CreateElement('Controller')
    $controller.SetAttribute('Mac',$mac)
    $controller.SetAttribute('ControllerType','DS4')
    [void]$ccRoot.AppendChild($controller)
}
$controller.SetAttribute('ControllerType','DS4')
$settingsNode=$controller.SelectSingleNode('DS4SupportSettings')
if(-not $settingsNode){
    $settingsNode=$cc.CreateElement('DS4SupportSettings')
    [void]$controller.AppendChild($settingsNode)
}
$copyNode=$settingsNode.SelectSingleNode('Copycat')
if(-not $copyNode){
    $copyNode=$cc.CreateElement('Copycat')
    [void]$settingsNode.AppendChild($copyNode)
}
$copyNode.InnerText='True'
Save-XmlUtf8 $cc $ccPath
Log ("Copycat=True para " + $mac)

# --- Link this physical controller to our profile ----------------------
$lpPath=Join-Path $ds4Root "LinkedProfiles.xml"
if(Test-Path -LiteralPath $lpPath){
    [xml]$lp=Get-Content -LiteralPath $lpPath -Raw -Encoding UTF8
} else {
    [xml]$lp='<?xml version="1.0" encoding="utf-8"?><LinkedControllers />'
}
$lpRoot=$lp.SelectSingleNode('/LinkedControllers')
if(-not $lpRoot){ Fail "LinkedProfiles.xml no tiene el formato esperado." }
$serial=$mac.Replace(':','').ToUpper()
$elementName='MAC'+$serial
$linkNode=$lpRoot.SelectSingleNode($elementName)
if(-not $linkNode){
    $linkNode=$lp.CreateElement($elementName)
    [void]$lpRoot.AppendChild($linkNode)
}
$linkNode.InnerText=$ProfileName
Save-XmlUtf8 $lp $lpPath
Log ("Perfil vinculado: " + $elementName + " -> " + $ProfileName)

# Restart DS4Windows so the updated profile is loaded immediately.
if($ds4Exe -and (Test-Path -LiteralPath $ds4Exe)){
    Start-Process -FilePath $ds4Exe
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host ("CONTROLADOR ACTUALIZADO - " + $Version) -ForegroundColor Green
Write-Host ""
Write-Host "Mapa actual:" -ForegroundColor Cyan
Write-Host "  Cruceta arriba = deseleccionar"
Write-Host "  Cruceta abajo = lapiz mas oscuro"
Write-Host "  Cruceta izquierda = deshacer"
Write-Host "  Cruceta derecha = borrador"
Write-Host "  X = alejar zoom"
Write-Host "  Circulo = acercar zoom"
Write-Host "  Cuadrado = bajar estabilizacion"
Write-Host "  Triangulo = subir estabilizacion"
Write-Host "  R1 = pincel"
Write-Host "  R2 = seleccionar todo"
Write-Host "  L3 = seleccionar todo"
Write-Host "  R3 = borrar seleccionados"
Write-Host "  L1 = rehacer; L2 = deshacer"
Write-Host ""
Write-Host "Se mantienen touchpad, Copycat, sticks y perfil vinculado." -ForegroundColor Green
Write-Host "Abre Clip Studio y prueba este mapa." -ForegroundColor Yellow
Write-Host ("Log: " + $log)
