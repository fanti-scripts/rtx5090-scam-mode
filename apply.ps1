#Requires -Version 5.1
<#
  RTX 5090 Scam Mode v3 - ПРИМЕНЕНИЕ

  Windows читает имя видеокарты из ТРЁХ разных мест, и правки нужны во всех:

    1. ...\Class\{4d36e968-...}\0000\DriverDesc
    2. ...\Enum\PCI\VEN_10DE&DEV_2187...\<instance>\DeviceDesc
       <- это то, что реально показывает Диспетчер устройств, dxdiag, WMI
       и «Параметры -> Система -> О системе»
    3. C:\Windows\INF\<oem>.inf, секция [Strings]
       <- чтобы имя не вернулось при переустановке устройства
#>
[CmdletBinding()]
param(
    [string]$GpuName = 'NVIDIA GeForce RTX 5090',
    [double]$VramGB  = 24          # у настоящей 5090 - 24 ГБ GDDR7
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath
$backupDir = Join-Path $scriptDir 'backup'

# ---------- повышение прав ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Nuzhny prava administratora. Perezapusk s povysheniem...' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"' + $PSCommandPath + '"'),
        '-GpuName', ('"' + $GpuName + '"'), '-VramGB', "$VramGB")
    exit
}

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$script:Ok = 0
$script:Failed = 0

function Set-RegVal {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    try {
        if ($null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) {
            Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -ErrorAction Stop
        } else {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        Write-Host ("    {0,-34} = {1}" -f $Name, $Value) -ForegroundColor DarkGreen
        $script:Ok++
        return $true
    } catch {
        Write-Host ("    {0,-34} ! {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
        return $false
    }
}

# Ключи Enum\PCI*\... защищены: писать в них может только SYSTEM.
function Unlock-Key {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($false, $true)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            'BUILTIN\Administrators',
            [System.Security.AccessControl.RegistryRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
            ([System.Security.AccessControl.PropagationFlags]::None),
            ([System.Security.AccessControl.AccessControlType]::Allow))
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        return $true
    } catch {
        Write-Host "    (unlock failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
        return $false
    }
}

function Patch-GpuKey {
    param([string]$Path, [long]$Bytes, [string]$Label)

    Write-Host "  [$Label]" -ForegroundColor Cyan
    # Формат настоящего драйвера: qwMemorySize = точный размер,
    # MemorySize = размер - 1 МБ, обрезанный до 32 бит.
    #
    # НЕЛЬЗЯ писать ($Bytes - 0x100000) -band 0xFFFFFFFF:
    # в PowerShell 5.1 литерал 0xFFFFFFFF разбирается как Int32 -1,
    # а не как 4294967295, поэтому -band ничего не обрезает и [uint32]
    # падает. Обрезаем по модулю.
    $qw = $Bytes
    $dw = [uint32](($Bytes - 0x100000) % [long]4294967296)

    Set-RegVal $Path 'DriverDesc'                        'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.AdapterString' 'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.ChipType'     'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.qwMemorySize' 'QWord'  ([uint64]$qw) | Out-Null
    Set-RegVal $Path 'HardwareInformation.MemorySize'   'DWord'  $dw | Out-Null
}

$bytes = [long]($VramGB * 1GB)
Write-Host "Cel: '$GpuName' / $VramGB GB ($bytes bayt)" -ForegroundColor Green

# ================= 1. Class\...\0000 =================
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$candidates = Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^[0-9A-Fa-f]{4}$' } |
    Where-Object {
        $d = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc
        $m = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'MatchingDeviceId' -ErrorAction SilentlyContinue).MatchingDeviceId
        $d -match 'NVIDIA' -or $m -match 'ven_10de'
    }

$target = $candidates | Where-Object { $_.PSChildName -eq '0000' } | Select-Object -First 1
if (-not $target) { $target = $candidates | Select-Object -First 1 }

Write-Host ''
if ($target) {
    & reg.exe export ("HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\" + $target.PSChildName) (Join-Path $backupDir "class-$($target.PSChildName)-$stamp.reg") /y | Out-Null
    Patch-GpuKey $target.PSPath $bytes "Class\$($target.PSChildName)"
} else {
    Write-Host 'NVIDIA GPU ne naydena v klase klassov!' -ForegroundColor Red
    $script:Failed++
}

# ================= 2. Control\Video =================
Write-Host ''
$videoKeys = Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Video' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
    Where-Object {
        $d = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc
        $m = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'MatchingDeviceId' -ErrorAction SilentlyContinue).MatchingDeviceId
        $d -match 'NVIDIA' -or $m -match 'ven_10de'
    }

$i = 0
foreach ($vk in $videoKeys) {
    $i++
    & reg.exe export ($vk.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE','HKLM') (Join-Path $backupDir "video-$i-$stamp.reg") /y 2>$null | Out-Null
    Patch-GpuKey $vk.PSPath $bytes "Video\$i"
}

# ================= 3. Enum\PCI (то, что видит Диспетчер устройств) =================
Write-Host ''
Write-Host '  [Enum\PCI - Device Manager / dxdiag / WMI]' -ForegroundColor Cyan
$enumKeys = Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^VEN_10DE&DEV_2187' } |
    ForEach-Object { Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue }

$infRef = $null
$infToken = $null

foreach ($ek in $enumKeys) {
    $regPath = $ek.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE','HKLM'
    & reg.exe export $regPath (Join-Path $backupDir ("enum-" + ($ek.PSChildName -replace '[^a-zA-Z0-9]','_') + "-$stamp.reg")) /y 2>$null | Out-Null

    Write-Host "    key: $($ek.PSChildName)" -ForegroundColor DarkGray
    Unlock-Key $ek.PSPath | Out-Null

    $cur = (Get-ItemProperty -LiteralPath $ek.PSPath -Name 'DeviceDesc' -ErrorAction SilentlyContinue).DeviceDesc
    if (-not $cur) { continue }

    # формат:  @oem4.inf,%token%;Отображаемое имя
    # ВАЖНО: ведущий '@' обязателен - он помечает значение как ссылку на INF.
    # Без него строка становится литералом и Windows перестаёт её обновлять.
    if ($cur -match '^@([^,]+),([^;]+);(.*)$') {
        if (-not $infRef) { $infRef = $Matches[1]; $infToken = $Matches[2].Trim('%') }
        $new = '@' + $Matches[1] + ',' + $Matches[2] + ';' + $GpuName
    } else {
        $new = $GpuName
    }
    Set-RegVal $ek.PSPath 'DeviceDesc' 'String' $new | Out-Null

    # FriendlyName, если он есть, тоже должен совпадать
    if ($null -ne (Get-ItemProperty -LiteralPath $ek.PSPath -Name 'FriendlyName' -ErrorAction SilentlyContinue)) {
        Set-RegVal $ek.PSPath 'FriendlyName' 'String' $GpuName | Out-Null
    }
}

# ================= 4. INF =================
if ($infRef -and $infToken) {
    Write-Host ''
    Write-Host "  [INF: $infRef, token $infToken]" -ForegroundColor Cyan
    $infPath = Join-Path $env:SystemRoot "INF\$infRef"
    if (Test-Path -LiteralPath $infPath) {
        $infBak = Join-Path $backupDir "$infRef.bak"
        Copy-Item -LiteralPath $infPath -Destination $infBak -Force
        # файл чисто ASCII без BOM - любая ASCII-совместимая кодировка
        # даёт побайтово идентичный результат
        $txt = [IO.File]::ReadAllText($infPath, [Text.Encoding]::ASCII)
        $esc = [regex]::Escape($infToken)
        $rx = [regex]::new('(?im)^(' + $esc + '\s*=\s*)"[^"]*"')
        if ($rx.IsMatch($txt)) {
            $txt2 = $rx.Replace($txt, '${1}"' + $GpuName + '"')
            [IO.File]::WriteAllText($infPath, $txt2, [Text.Encoding]::ASCII)
            Write-Host ("    {0} -> {1}" -f $infToken, $GpuName) -ForegroundColor DarkGreen
            Write-Host "    backup: $infBak" -ForegroundColor DarkGray
            $script:Ok++
        } else {
            Write-Host "    token '$infToken' ne najden v INF" -ForegroundColor Red
            $script:Failed++
        }
    } else {
        Write-Host "    $infPath ne najden" -ForegroundColor Red
        $script:Failed++
    }
}

Write-Host ''
Write-Host "Zapiseano: $script:Ok   Oshibok: $script:Failed" -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed -gt 0) {
    Write-Host 'EST OSHIBKI - sm. krasnye stroki vyshe.' -ForegroundColor Red
} else {
    Write-Host '=== GOTOVO. TEPER REBOOT ===' -ForegroundColor Green
}
Write-Host 'Posle reboota zapusti 3_PROVERIT.cmd' -ForegroundColor Cyan
Write-Host 'Otkat: 2_OTKAT.cmd' -ForegroundColor Cyan
Read-Host 'Nazmi Enter'