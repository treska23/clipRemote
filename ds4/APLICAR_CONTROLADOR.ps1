$ErrorActionPreference = "Stop"

$Version = "2026.09.03-2"
$RawBase = "https://raw.githubusercontent.com/treska23/clipRemote/main/ds4"
$ProfileUrl = "$RawBase/ClipStudio_DualShock4.xml"
$ProfileName = "ClipStudio_DualShock4.xml"
$LogDir = Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Log = Join-Path $LogDir ("update_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")

function Log([string]$Text = "") { Add-Content -LiteralPath $Log -Value $Text -Encoding UTF8 }
function Fail([string]$Text) {
    Log ("ERROR: " + $Text)
    Write-Host ""
    Write-Host ("ERROR: " + $Text) -ForegroundColor Red
    Write-Host ("Log: " + $Log)
    exit 1
}
function Download([string]$Url,[string]$Out) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
    }
    catch {
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if(-not $curl){ throw }
        & $curl.Source -L --fail --output $Out $Url
        if($LASTEXITCODE -ne 0){ throw "No se pudo descargar $Url" }
    }
}
function Get-Sqlite {
    $tools = Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater\tools"
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $exe = Get-ChildItem -LiteralPath $tools -Filter sqlite3.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if($exe){ return $exe.FullName }

    $zip = Join-Path $tools "sqlite.zip"
    $extract = Join-Path $tools "sqlite"
    Download "https://www.sqlite.org/2026/sqlite-tools-win-x64-3530400.zip" $zip
    if(Test-Path $extract){ Remove-Item $extract -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $exe = Get-ChildItem -LiteralPath $extract -Filter sqlite3.exe -File -Recurse | Select-Object -First 1
    if(-not $exe){ throw "sqlite3.exe no encontrado" }
    return $exe.FullName
}
function Sql([string]$Exe,[string]$Db,[string]$Query) {
    $r = & $Exe $Db $Query 2>&1 | Out-String
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
        $base = Split-Path (Split-Path $db.FullName -Parent) -Parent
        $tool = Join-Path $base "Tool\EditImageTool.todb"
        if(Test-Path -LiteralPath $tool){
            return [pscustomobject]@{ Base=$base; ShortcutDb=$db.FullName; ToolDb=$tool }
        }
    }
    return $null
}

"CLIP STUDIO + DUALSHOCK 4 - ACTUALIZADOR REMOTO $Version" | Set-Content -LiteralPath $Log -Encoding UTF8
Log ("Fecha: " + (Get-Date))

if(Get-Process CLIPStudioPaint -ErrorAction SilentlyContinue){
    Fail "Cierra CLIP STUDIO PAINT y vuelve a ejecutar el actualizador."
}

$tempProfile = Join-Path $env:TEMP ("ClipStudio_DualShock4_" + [guid]::NewGuid().ToString("N") + ".xml")
Download $ProfileUrl $tempProfile
try { [xml](Get-Content -LiteralPath $tempProfile -Raw -Encoding UTF8) | Out-Null }
catch { Fail "El perfil remoto no es XML valido. No se ha instalado." }

$csp = Find-Csp
if(-not $csp){ Fail "No encuentro default.khc y EditImageTool.todb de Clip Studio." }
$sqlite = Get-Sqlite
if((Sql $sqlite $csp.ShortcutDb "PRAGMA integrity_check;") -ne "ok"){ Fail "default.khc no pasa integrity_check." }
if((Sql $sqlite $csp.ToolDb "PRAGMA integrity_check;") -ne "ok"){ Fail "EditImageTool.todb no pasa integrity_check." }

$backupDir = Join-Path $csp.Base "DS4Controller_Backups"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp=Get-Date -Format "yyyyMMdd_HHmmss"
$khcBackup=Join-Path $backupDir ("default_"+$stamp+".khc")
$toolBackup=Join-Path $backupDir ("EditImageTool_"+$stamp+".todb")
Copy-Item $csp.ShortcutDb $khcBackup -Force
Copy-Item $csp.ToolDb $toolBackup -Force
Log ("Backup CSP: " + $backupDir)

try {
    # Dedicated plain function keys used only as the bridge from DS4Windows to CSP.
    # F2/F3 are now stabilization -/+ because F6/F7 were unreliable on this setup.
    $menuMap=@(
        @("toolbrushrevisionminus","F2"),
        @("toolbrushrevisionplus","F3"),
        @("viewzoomout","F8"),
        @("viewzoomin","F9"),
        @("layerrasternew","F10"),
        @("layerdelete","F11"),
        @("layerselectupperlayer","F12"),
        @("layerselectlowerlayer","F13"),
        @("canvasscrollleft","F14"),
        @("canvasscrollright","F15"),
        @("canvasscrollup","F16"),
        @("canvasscrolldown","F17")
    )

    foreach($p in $menuMap){
        $cmd=$p[0].Replace("'","''")
        $key=$p[1].Replace("'","''")
        $count=[int](Sql $sqlite $csp.ShortcutDb ("SELECT COUNT(*) FROM shortcutmenu WHERE menucommand='"+$cmd+"';"))
        if($count -gt 0){
            Sql $sqlite $csp.ShortcutDb ("UPDATE shortcutmenu SET shortcut=NULL, modifier=0 WHERE shortcut='"+$key+"' AND modifier=0 AND menucommand<>'"+$cmd+"';") | Out-Null
            Sql $sqlite $csp.ShortcutDb ("UPDATE shortcutmenu SET shortcut='"+$key+"', modifier=0 WHERE menucommand='"+$cmd+"';") | Out-Null
            Log ("CSP " + $cmd + " -> " + $key)
        } else {
            Log ("CSP NO ENCONTRADO: " + $cmd)
        }
    }

    # Exact requested subtool: Lápiz más oscuro -> F5.
    $safe="Lápiz más oscuro".Replace("'","''")
    $n=[int](Sql $sqlite $csp.ToolDb ("SELECT COUNT(*) FROM Node WHERE NodeName='"+$safe+"';"))
    if($n -lt 1){
        $candidate=Sql $sqlite $csp.ToolDb "SELECT NodeName FROM Node WHERE lower(NodeName) LIKE '%oscuro%' LIMIT 1;"
        if(-not $candidate){ throw "No encuentro la subherramienta Lapiz mas oscuro." }
        $safe=$candidate.Replace("'","''")
    }
    Sql $sqlite $csp.ToolDb ("UPDATE Node SET NodeShortCutKey=0 WHERE NodeShortCutKey=41 AND NodeName<>'"+$safe+"';") | Out-Null
    Sql $sqlite $csp.ToolDb ("UPDATE Node SET NodeShortCutKey=41 WHERE NodeName='"+$safe+"';") | Out-Null

    if((Sql $sqlite $csp.ShortcutDb "PRAGMA integrity_check;") -ne "ok" -or (Sql $sqlite $csp.ToolDb "PRAGMA integrity_check;") -ne "ok"){
        throw "Integrity check fallo despues de aplicar cambios."
    }
}
catch {
    Copy-Item $khcBackup $csp.ShortcutDb -Force
    Copy-Item $toolBackup $csp.ToolDb -Force
    Fail ("Error configurando Clip Studio; se restauro el backup: " + $_.Exception.Message)
}

$profilesDir=Join-Path $env:APPDATA "DS4Windows\Profiles"
New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
$target=Join-Path $profilesDir $ProfileName

$ds4=@(Get-Process DS4Windows -ErrorAction SilentlyContinue)
$ds4Exe=$null
if($ds4.Count -gt 0){
    try{$ds4Exe=$ds4[0].Path}catch{}
    $ds4 | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

if(Test-Path $target){ Copy-Item $target ($target+".bak_"+$stamp) -Force }
Copy-Item $tempProfile $target -Force
Remove-Item $tempProfile -Force -ErrorAction SilentlyContinue
Log ("Perfil DS4Windows instalado: " + $target)

if($ds4Exe -and (Test-Path $ds4Exe)){ Start-Process $ds4Exe }

Write-Host ""
Write-Host ("CONTROLADOR ACTUALIZADO - " + $Version) -ForegroundColor Green
Write-Host "Estabilizacion: cruceta izquierda/derecha = F2/F3" -ForegroundColor Green
Write-Host "Touchpad: modo raton forzado + click izquierdo" -ForegroundColor Green
Write-Host ""
Write-Host "Si DS4Windows no conserva el perfil en el mando, selecciona ClipStudio_DualShock4 una vez en Controllers." -ForegroundColor Yellow
Write-Host ("Log: " + $Log)
