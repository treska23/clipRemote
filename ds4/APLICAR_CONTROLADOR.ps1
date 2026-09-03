$ErrorActionPreference = "Continue"

$Version = "2026.09.03-DIAG1"
$desktop = [Environment]::GetFolderPath("Desktop")
$report = Join-Path $desktop "DIAGNOSTICO_DS4_CLIPSTUDIO.txt"

function Add([string]$s = "") {
    Add-Content -LiteralPath $report -Value $s -Encoding UTF8
}

function Redact([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    # Redact MAC-like identifiers and long device serial tails while keeping VID/PID visible.
    $s = [regex]::Replace($s, '(?i)([0-9A-F]{2}[:-]){5}[0-9A-F]{2}', '<MAC>')
    $s = [regex]::Replace($s, '(?i)(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})\\[^\s<]+', '$1\\<SERIAL>')
    return $s
}

"DIAGNOSTICO DS4WINDOWS + CLIP STUDIO" | Set-Content -LiteralPath $report -Encoding UTF8
Add ("Version diagnostico: " + $Version)
Add ("Fecha: " + (Get-Date))
Add ""

Add "[1] DS4WINDOWS EN EJECUCION"
$procs = @(Get-Process DS4Windows -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Add "DS4Windows: NO ESTA EJECUTANDOSE"
} else {
    foreach ($p in $procs) {
        $path = $null
        try { $path = $p.Path } catch {}
        Add ("PID=" + $p.Id)
        Add ("Path=" + $path)
        if ($path -and (Test-Path -LiteralPath $path)) {
            try {
                $v = (Get-Item -LiteralPath $path).VersionInfo
                Add ("FileVersion=" + $v.FileVersion)
                Add ("ProductVersion=" + $v.ProductVersion)
            } catch {}
        }
    }
}
Add ""

Add "[2] CARPETAS DE CONFIGURACION DS4WINDOWS"
$candidates = @()
$candidates += (Join-Path $env:APPDATA "DS4Windows")
foreach ($p in $procs) {
    try {
        $exeDir = Split-Path $p.Path -Parent
        if ($exeDir) { $candidates += $exeDir }
    } catch {}
}
$candidates = @($candidates | Where-Object { $_ } | Select-Object -Unique)

foreach ($dir in $candidates) {
    Add ("DIR: " + $dir + " | existe=" + (Test-Path -LiteralPath $dir))
    if (Test-Path -LiteralPath $dir) {
        foreach ($name in @("Profiles.xml","ControllerConfigs.xml","Auto Profiles.xml")) {
            $f = Join-Path $dir $name
            if (Test-Path -LiteralPath $f) {
                $fi = Get-Item -LiteralPath $f
                Add ("  " + $name + " | mod=" + $fi.LastWriteTime + " | bytes=" + $fi.Length)
                try {
                    Add ("  CONTENIDO " + $name + ":")
                    $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
                    Add (Redact $raw)
                } catch { Add ("  ERROR leyendo: " + $_.Exception.Message) }
            }
        }

        $profile = Join-Path $dir "Profiles\ClipStudio_DualShock4.xml"
        Add ("  Perfil ClipStudio_DualShock4: existe=" + (Test-Path -LiteralPath $profile))
        if (Test-Path -LiteralPath $profile) {
            $fi = Get-Item -LiteralPath $profile
            Add ("  Perfil mod=" + $fi.LastWriteTime + " | bytes=" + $fi.Length)
            try { Add ("  SHA256=" + (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash) } catch {}
            try {
                [xml]$x = Get-Content -LiteralPath $profile -Raw -Encoding UTF8
                $n = $x.DS4Windows
                Add ("  touchToggle=" + $n.touchToggle)
                Add ("  StartTouchpadOff=" + $n.StartTouchpadOff)
                Add ("  TouchpadOutputMode=" + $n.TouchpadOutputMode)
                Add ("  TouchpadClickPassthru=" + $n.TouchpadClickPassthru)
                Add ("  TouchpadButtonMode=" + $n.TouchpadButtonMode)
                Add ("  DpadLeft key=" + $n.Control.Key.DpadLeft)
                Add ("  DpadRight key=" + $n.Control.Key.DpadRight)
                Add ("  TouchLeft button=" + $n.Control.Button.TouchLeft)
                Add ("  TouchRight button=" + $n.Control.Button.TouchRight)
                Add ("  TouchUpper button=" + $n.Control.Button.TouchUpper)
                Add ("  TouchMulti button=" + $n.Control.Button.TouchMulti)
            } catch { Add ("  ERROR parseando perfil: " + $_.Exception.Message) }
        }
    }
}
Add ""

Add "[3] DISPOSITIVOS HID / MANDO"
try {
    $devs = Get-CimInstance Win32_PnPEntity | Where-Object {
        $_.Name -match '(?i)wireless controller|dualshock|game controller|controller|HID-compliant game' -or
        $_.PNPDeviceID -match '(?i)VID_054C|VID_0F0D|VID_057E'
    }
    foreach ($d in $devs) {
        $id = Redact ([string]$d.PNPDeviceID)
        Add ("Name=" + $d.Name + " | Status=" + $d.Status + " | PNP=" + $id)
    }
} catch { Add ("ERROR enumerando dispositivos: " + $_.Exception.Message) }
Add ""

Add "[4] CLIP STUDIO - BASE DE ATAJOS"
$docs=[Environment]::GetFolderPath("MyDocuments")
$roots=@(
    (Join-Path $docs "CELSYS"),(Join-Path $docs "CELSYS_EN"),
    (Join-Path $env:APPDATA "CELSYS"),(Join-Path $env:APPDATA "CELSYS_EN"),
    (Join-Path $env:USERPROFILE "OneDrive\Documentos\CELSYS"),
    (Join-Path $env:USERPROFILE "OneDrive\Documents\CELSYS")
) | Select-Object -Unique
$khcs=@()
foreach($r in $roots){
    if($r -and (Test-Path -LiteralPath $r)){
        $khcs += Get-ChildItem -LiteralPath $r -Filter default.khc -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object {$_.FullName -match '[\\/]Shortcut[\\/]default\.khc$'}
    }
}
$khc = $khcs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $khc){
    Add "default.khc: NO ENCONTRADO"
} else {
    Add ("default.khc=" + $khc.FullName)
    Add ("mod=" + $khc.LastWriteTime + " | bytes=" + $khc.Length)
    $sqlite = Get-ChildItem (Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater") -Filter sqlite3.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $sqlite){
        Add "sqlite3.exe del actualizador: NO ENCONTRADO"
    } else {
        Add ("sqlite3.exe=" + $sqlite.FullName)
        $q = @"
.mode list
.separator |
SELECT menucommand, COALESCE(shortcut,'NULL'), modifier FROM shortcutmenu
WHERE menucommand IN ('toolbrushrevisionminus','toolbrushrevisionplus','toolbrushuserevision','toolflickerreductionminus','toolflickerreductionplus')
   OR shortcut IN ('F2','F3','F6','F7')
ORDER BY menucommand, shortcut;
"@
        try {
            $out = $q | & $sqlite.FullName $khc.FullName 2>&1 | Out-String
            Add "Comandos revision/estabilizacion y F2/F3/F6/F7:"
            Add $out.Trim()
        } catch { Add ("ERROR SQLite: " + $_.Exception.Message) }
    }
}
Add ""

Add "[5] ULTIMOS LOGS DEL ACTUALIZADOR"
$logDir = Join-Path $env:LOCALAPPDATA "ClipStudioDS4Updater"
if(Test-Path -LiteralPath $logDir){
    $logs = Get-ChildItem -LiteralPath $logDir -Filter "update_*.txt" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
    foreach($l in $logs){
        Add ("--- " + $l.Name + " | " + $l.LastWriteTime + " ---")
        try { Add (Get-Content -LiteralPath $l.FullName -Raw -Encoding UTF8) } catch {}
    }
}
Add ""
Add "FIN DEL DIAGNOSTICO"

Write-Host ""
Write-Host "DIAGNOSTICO CREADO." -ForegroundColor Green
Write-Host $report -ForegroundColor Yellow
Write-Host ""
Write-Host "No se ha cambiado ningun perfil ni ningun atajo." -ForegroundColor Cyan
Write-Host "Arrastra DIAGNOSTICO_DS4_CLIPSTUDIO.txt al chat." -ForegroundColor Cyan
