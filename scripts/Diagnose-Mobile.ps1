param(
    [string]$Device
)

$ErrorActionPreference = 'Stop'

function Find-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw 'No encuentro adb.exe.'
}

function Get-ConnectedDevices {
    param([string]$Adb)

    return @(& $Adb devices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice$' } |
        ForEach-Object { $_ -replace '\s+device$', '' })
}

function Get-DeviceInfo {
    param([string]$Adb, [string]$Serial)

    $manufacturer = (& $Adb -s $Serial shell getprop ro.product.manufacturer 2>$null).Trim()
    $model = (& $Adb -s $Serial shell getprop ro.product.model 2>$null).Trim()
    $abi = (& $Adb -s $Serial shell getprop ro.product.cpu.abilist 2>$null).Trim()

    [pscustomobject]@{
        Serial = $Serial
        Manufacturer = $manufacturer
        Model = $model
        Abi = $abi
    }
}

function Select-Oppo {
    param([string]$Adb, [string]$RequestedDevice)

    $devices = Get-ConnectedDevices $Adb
    if (-not $devices) { throw 'No hay dispositivos ADB conectados.' }

    if ($RequestedDevice) {
        if ($devices -notcontains $RequestedDevice) {
            throw "El dispositivo '$RequestedDevice' no está conectado por ADB."
        }
        return Get-DeviceInfo $Adb $RequestedDevice
    }

    $infos = @($devices | ForEach-Object { Get-DeviceInfo $Adb $_ })
    $oppo = $infos | Where-Object {
        $_.Manufacturer -match 'OPPO' -or $_.Model -match '^CPH\d+'
    } | Select-Object -First 1

    if ($oppo) { return $oppo }

    Write-Host 'Dispositivos ADB detectados:' -ForegroundColor Yellow
    $infos | ForEach-Object {
        Write-Host "  $($_.Serial)  $($_.Manufacturer) $($_.Model)  ABI=$($_.Abi)"
    }
    throw 'No encuentro un Oppo. No ejecutaré nada para evitar tocar la TV por error.'
}

$adb = Find-Adb
$phone = Select-Oppo $adb $Device
$serial = $phone.Serial
$package = 'com.treska23.clipremote'
$activity = 'com.treska23.clipremote/.MainActivity'

Write-Host "ADB: $adb"
Write-Host "Móvil: $($phone.Manufacturer) $($phone.Model)"
Write-Host "Serial: $serial"
Write-Host "ABI: $($phone.Abi)"
Write-Host ''

$installed = (& $adb -s $serial shell pm list packages $package 2>$null) -join "`n"
if ($installed -notmatch [regex]::Escape($package)) {
    throw 'ClipRemote no está instalado en el Oppo.'
}

Write-Host 'ClipRemote está instalado. Limpiando logcat y lanzando la app...'
& $adb -s $serial logcat -c | Out-Null
& $adb -s $serial shell am force-stop $package | Out-Null

$startOutput = & $adb -s $serial shell am start -W -n $activity 2>&1
$startOutput | ForEach-Object { Write-Host $_ }

Start-Sleep -Seconds 2

$pid = ((& $adb -s $serial shell pidof $package 2>$null) -join '').Trim()
Write-Host ''
if ($pid) {
    Write-Host "PROCESO VIVO · PID $pid" -ForegroundColor Green
} else {
    Write-Host 'PROCESO MUERTO · la app se cerró después de arrancar' -ForegroundColor Red
}

$resumed = (& $adb -s $serial shell dumpsys activity activities 2>$null |
    Select-String -Pattern 'mResumedActivity|topResumedActivity' |
    Select-Object -First 4) -join "`n"

if ($resumed) {
    Write-Host ''
    Write-Host 'ACTIVIDAD EN PRIMER PLANO:'
    Write-Host $resumed
}

Write-Host ''
Write-Host 'ERRORES RELEVANTES DE LOGCAT:' -ForegroundColor Cyan
$logs = & $adb -s $serial logcat -d -v threadtime 2>$null
$relevant = $logs | Where-Object {
    $_ -match 'AndroidRuntime|FATAL EXCEPTION|clipremote|monodroid|dotnet|libmonosgen|SIGABRT|SIGSEGV|UnsatisfiedLinkError|DllNotFoundException|TypeInitializationException|Unhandled Exception'
}

if ($relevant) {
    $relevant | Select-Object -Last 120 | ForEach-Object { Write-Host $_ }
} else {
    Write-Host '(No aparecen errores relevantes en logcat.)'
}
