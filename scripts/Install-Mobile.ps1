param(
    [string]$Apk,
    [string]$Device
)

$ErrorActionPreference = 'Stop'

function Find-Adb {
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw 'No encuentro adb.exe. Instala Android Platform Tools o añade adb al PATH.'
}

function Find-Apk {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        return (Resolve-Path $RequestedPath -ErrorAction Stop).Path
    }

    $roots = @(
        (Join-Path $PSScriptRoot '..\artifacts\ClipRemote.Mobile'),
        (Join-Path $PSScriptRoot '..\src\ClipRemote.Mobile\bin\Debug\net10.0-android'),
        (Join-Path $HOME 'Downloads')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }

        $match = Get-ChildItem $root -File -Recurse -Filter '*.apk' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'clipremote|Signed' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($match) { return $match.FullName }
    }

    throw 'No encuentro el APK. Pasa su ruta con -Apk "C:\ruta\ClipRemote-Mobile.apk".'
}

function Get-ConnectedDevices {
    param([string]$Adb)

    return @(& $Adb devices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice$' } |
        ForEach-Object { $_ -replace '\s+device$', '' })
}

function Ensure-WirelessDevice {
    param([string]$Adb, [string]$RequestedDevice)

    if ($RequestedDevice) {
        & $Adb connect $RequestedDevice | Write-Host
    }

    $devices = Get-ConnectedDevices $Adb
    if ($devices.Count -gt 0) {
        if ($RequestedDevice) {
            $match = $devices | Where-Object { $_ -eq $RequestedDevice } | Select-Object -First 1
            if ($match) { return $match }
        }
        return $devices[0]
    }

    Write-Host ''
    Write-Host 'No hay ningún Oppo conectado por ADB.' -ForegroundColor Yellow
    Write-Host 'En el Oppo abre: Opciones de desarrollador > Depuración inalámbrica.'
    Write-Host 'Pulsa "Vincular dispositivo con código de vinculación".'
    $pairEndpoint = Read-Host 'Escribe aquí la IP:PUERTO de vinculación (Enter para cancelar)'
    if (-not $pairEndpoint) {
        throw 'Emparejamiento cancelado.'
    }

    & $Adb pair $pairEndpoint
    if ($LASTEXITCODE -ne 0) {
        throw 'adb pair no pudo emparejar el Oppo.'
    }

    $connectEndpoint = Read-Host 'Ahora escribe la IP:PUERTO que aparece en la pantalla principal de Depuración inalámbrica'
    if (-not $connectEndpoint) {
        throw 'Falta la dirección de conexión ADB.'
    }

    & $Adb connect $connectEndpoint | Write-Host
    $devices = Get-ConnectedDevices $Adb
    $match = $devices | Where-Object { $_ -eq $connectEndpoint } | Select-Object -First 1
    if (-not $match) {
        throw 'El Oppo se emparejó, pero ADB no aparece conectado.'
    }

    return $match
}

function Get-AgentProvisioning {
    $settingsPath = Join-Path $env:LOCALAPPDATA 'ClipRemote\settings.json'
    if (-not (Test-Path $settingsPath)) { return $null }

    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if (-not $settings.pairingToken -or -not $settings.port) { return $null }

    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

    $ip = $null
    if ($route) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -ExpandProperty IPAddress -First 1
    }

    if (-not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' -or $_.IPAddress -like '172.*' } |
            Select-Object -ExpandProperty IPAddress -First 1
    }

    if (-not $ip) { return $null }

    return [pscustomobject]@{
        Address = "$ip`:$($settings.port)"
        Token = [string]$settings.pairingToken
    }
}

$adb = Find-Adb
$serial = Ensure-WirelessDevice $adb $Device
$apkPath = Find-Apk $Apk

Write-Host "ADB: $adb"
Write-Host "Oppo: $serial"
Write-Host "APK: $apkPath"
Write-Host 'Instalando/actualizando ClipRemote...'

& $adb -s $serial install -r $apkPath
if ($LASTEXITCODE -ne 0) {
    throw "adb install falló con código $LASTEXITCODE."
}

$provisioning = Get-AgentProvisioning
& $adb -s $serial shell am force-stop com.treska23.clipremote | Out-Null

if ($provisioning) {
    Write-Host "Configurando automáticamente el Agent en $($provisioning.Address)..."
    & $adb -s $serial shell am start `
        -n com.treska23.clipremote/.MainActivity `
        --es address $provisioning.Address `
        --es token $provisioning.Token `
        --ez autoconnect true | Out-Null
} else {
    Write-Host 'No pude leer la configuración local del Agent; abro la app para configurarla a mano.' -ForegroundColor Yellow
    & $adb -s $serial shell am start -n com.treska23.clipremote/.MainActivity | Out-Null
}

Write-Host 'ClipRemote instalado y abierto en el Oppo.' -ForegroundColor Green
