param(
    [string]$Apk,
    [string]$Device
)

$ErrorActionPreference = 'Stop'

function Find-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    throw 'No encuentro adb.exe. Instala Android Platform Tools o añade adb al PATH.'
}

function Find-Apk {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $resolved = Resolve-Path $RequestedPath -ErrorAction Stop
        return $resolved.Path
    }

    $patterns = @(
        (Join-Path $PSScriptRoot '..\artifacts\ClipRemote.Mobile\*.apk'),
        (Join-Path $PSScriptRoot '..\src\ClipRemote.Mobile\bin\Debug\net10.0-android\**\*.apk'),
        (Join-Path $HOME 'Downloads\ClipRemote*.apk'),
        (Join-Path $HOME 'Downloads\*clipremote*.apk')
    )

    foreach ($pattern in $patterns) {
        $match = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($match) {
            return $match.FullName
        }
    }

    throw 'No encuentro el APK. Pasa su ruta con -Apk "C:\ruta\ClipRemote.apk".'
}

$adb = Find-Adb
Write-Host "ADB: $adb"

if ($Device) {
    Write-Host "Conectando con $Device..."
    & $adb connect $Device | Write-Host
}

$deviceLines = & $adb devices |
    Select-Object -Skip 1 |
    Where-Object { $_ -match '\sdevice$' }

if (-not $deviceLines) {
    throw 'No hay ningún Android conectado por ADB. Activa Depuración inalámbrica y empareja/conecta el Oppo primero.'
}

$serial = if ($Device) {
    ($deviceLines | Where-Object { $_ -like "$Device*" } | Select-Object -First 1) -replace '\s+device$', ''
} else {
    ($deviceLines | Select-Object -First 1) -replace '\s+device$', ''
}

if (-not $serial) {
    throw 'ADB está activo, pero no encuentro el dispositivo solicitado.'
}

$apkPath = Find-Apk $Apk
Write-Host "Dispositivo: $serial"
Write-Host "APK: $apkPath"
Write-Host 'Instalando/actualizando ClipRemote...'

& $adb -s $serial install -r $apkPath
if ($LASTEXITCODE -ne 0) {
    throw "adb install falló con código $LASTEXITCODE."
}

Write-Host 'Abriendo ClipRemote en el Oppo...'
& $adb -s $serial shell monkey -p com.treska23.clipremote -c android.intent.category.LAUNCHER 1 | Out-Null

Write-Host 'ClipRemote instalado y abierto.'
