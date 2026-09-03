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

function Get-DeviceInfo {
    param([string]$Adb, [string]$Serial)

    $manufacturer = (& $Adb -s $Serial shell getprop ro.product.manufacturer 2>$null).Trim()
    $model = (& $Adb -s $Serial shell getprop ro.product.model 2>$null).Trim()
    $characteristics = (& $Adb -s $Serial shell getprop ro.build.characteristics 2>$null).Trim()

    return [pscustomobject]@{
        Serial = $Serial
        Manufacturer = $manufacturer
        Model = $model
        Characteristics = $characteristics
        IsTv = ($characteristics -match '(^|,)tv(,|$)' -or $manufacturer -match '^Sony$')
        IsOppo = ($manufacturer -match '^(OPPO|Oppo)$')
    }
}

function Select-MobileDevice {
    param([string]$Adb, [string[]]$Serials, [string]$RequestedDevice)

    if ($RequestedDevice) {
        $exact = $Serials | Where-Object { $_ -eq $RequestedDevice } | Select-Object -First 1
        if (-not $exact) {
            throw "El dispositivo ADB solicitado '$RequestedDevice' no está conectado."
        }

        $info = Get-DeviceInfo $Adb $exact
        if ($info.IsTv) {
            throw "'$RequestedDevice' es $($info.Manufacturer) $($info.Model), un televisor. No voy a instalar ClipRemote ahí."
        }
        return $info
    }

    $infos = @($Serials | ForEach-Object { Get-DeviceInfo $Adb $_ })
    if ($infos.Count -eq 0) { return $null }

    Write-Host ''
    Write-Host 'Dispositivos ADB detectados:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $infos.Count; $i++) {
        $kind = if ($infos[$i].IsTv) { 'TV' } else { 'móvil/tablet' }
        Write-Host "  [$($i + 1)] $($infos[$i].Manufacturer) $($infos[$i].Model) · $kind · $($infos[$i].Serial)"
    }

    $oppo = $infos | Where-Object { $_.IsOppo -and -not $_.IsTv } | Select-Object -First 1
    if ($oppo) {
        Write-Host "Seleccionado automáticamente: $($oppo.Manufacturer) $($oppo.Model)" -ForegroundColor Green
        return $oppo
    }

    $mobiles = @($infos | Where-Object { -not $_.IsTv })
    if ($mobiles.Count -eq 1) {
        Write-Host "Seleccionado: $($mobiles[0].Manufacturer) $($mobiles[0].Model)" -ForegroundColor Green
        return $mobiles[0]
    }

    if ($mobiles.Count -gt 1) {
        throw 'Hay varios móviles/tablets ADB conectados y ninguno se identifica como OPPO. Usa -Device <serial> para elegir.'
    }

    return $null
}

function Ensure-WirelessDevice {
    param([string]$Adb, [string]$RequestedDevice)

    if ($RequestedDevice -and $RequestedDevice -match '^\d+\.\d+\.\d+\.\d+:\d+$') {
        & $Adb connect $RequestedDevice | Write-Host
    }

    $serials = Get-ConnectedDevices $Adb
    $selected = Select-MobileDevice $Adb $serials $RequestedDevice
    if ($selected) { return $selected }

    Write-Host ''
    Write-Host 'No hay ningún móvil válido conectado por ADB.' -ForegroundColor Yellow
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
    $serials = Get-ConnectedDevices $Adb
    $selected = Select-MobileDevice $Adb $serials $connectEndpoint
    if (-not $selected) {
        throw 'El Oppo se emparejó, pero no aparece como dispositivo ADB válido.'
    }

    return $selected
}

function Get-DeviceAbi {
    param([string]$Adb, [string]$Serial)

    $abiList = (& $Adb -s $Serial shell getprop ro.product.cpu.abilist).Trim()
    if (-not $abiList) {
        $abiList = (& $Adb -s $Serial shell getprop ro.product.cpu.abi).Trim()
    }

    return $abiList
}

function Assert-ApkLooksCompatible {
    param([string]$AbiList, [string]$ApkPath)

    if ($AbiList -notmatch 'arm64-v8a' -and $ApkPath -match 'arm64') {
        throw "El móvil solo anuncia '$AbiList', pero el APK es ARM64. Usa ClipRemote-Mobile-armv7.apk."
    }

    if ($AbiList -match 'armeabi-v7a' -and $ApkPath -match 'armv7|android-arm') {
        return
    }
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
$deviceInfo = Ensure-WirelessDevice $adb $Device
$serial = $deviceInfo.Serial
$apkPath = Find-Apk $Apk
$abiList = Get-DeviceAbi $adb $serial
Assert-ApkLooksCompatible $abiList $apkPath

Write-Host "ADB: $adb"
Write-Host "Móvil: $($deviceInfo.Manufacturer) $($deviceInfo.Model)"
Write-Host "Serial: $serial"
Write-Host "ABI: $abiList"
Write-Host "APK: $apkPath"
Write-Host 'Instalando/actualizando ClipRemote...'

& $adb -s $serial install -r $apkPath
if ($LASTEXITCODE -ne 0) {
    throw "adb install falló con código $LASTEXITCODE."
}

$provisioning = Get-AgentProvisioning
& $adb -s $serial shell am force-stop com.treska23.clipremote | Out-Null
$component = 'com.treska23.clipremote/com.treska23.clipremote.MainActivity'

if ($provisioning) {
    Write-Host "Configurando automáticamente el Agent en $($provisioning.Address)..."
    $launchOutput = & $adb -s $serial shell am start -W `
        -n $component `
        --es address $provisioning.Address `
        --es token $provisioning.Token `
        --ez autoconnect true 2>&1
} else {
    Write-Host 'No pude leer la configuración local del Agent; abro la app para configurarla a mano.' -ForegroundColor Yellow
    $launchOutput = & $adb -s $serial shell am start -W -n $component 2>&1
}

$launchOutput | Write-Host
if ($LASTEXITCODE -ne 0 -or ($launchOutput -join "`n") -match 'Error type|does not exist|unable to resolve') {
    throw 'ClipRemote se instaló, pero Android no pudo abrir la Activity.'
}

Write-Host 'ClipRemote instalado y abierto en el Oppo.' -ForegroundColor Green
