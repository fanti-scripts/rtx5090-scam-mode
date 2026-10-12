#Requires -Version 5.1
<#
  RTX 5090 Scam Mode v4 - ПРИМЕНЕНИЕ

  Windows берёт имя видеокарты из трёх независимых мест, поэтому правятся все три:

    1. ...\Control\Class\{4d36e968-...}\000N   DriverDesc + HardwareInformation.*
    2. ...\Enum\PCI\VEN_xxxx&DEV_xxxx\&...    DeviceDesc  <- Диспетчер устройств,
                                                 dxdiag, WMI, «Параметры -> О системе»
    3. C:\Windows\INF\<oem>.inf, [Strings]     чтобы имя не вернулось при
                                                 переустановке драйвера

  Адаптеры находятся по ClassGUID класса Display, поэтому скрипт не привязан
  к конкретной модели и работает с NVIDIA / AMD / Intel.

  Параметры:
    -GpuName   имя, которое будет показывать система
    -VramGB    объём видеопамяти
    -Vendor    auto (по умолчанию) | nvidia | amd | intel | any
    -Index     номер адаптера из списка (1-based). 0 = спросить, если их несколько
    -All       переименовать все найденные адаптеры (осторожно на ноутбуках:
                встроенная графика тоже станет «RTX 5090»)
    -DryRun    ничего не записывать, только показать, что было бы изменено.
               Полезно на незнакомой машине, чтобы проверить выбор адаптера.
#>
[CmdletBinding()]
param(
    [string]$GpuName = 'NVIDIA GeForce RTX 5090',
    [double]$VramGB  = 24,                     # у настоящей 5090 - 24 ГБ GDDR7
    [ValidateSet('auto','nvidia','amd','intel','any')]
    [string]$Vendor  = 'auto',
    [int]$Index      = 0,
    [switch]$All,
    [switch]$DryRun
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
        '-GpuName', ('"' + $GpuName + '"'), '-VramGB', "$VramGB", '-Vendor', $Vendor,
        '-Index', "$Index") -WorkingDirectory $scriptDir
    exit
}

if ($DryRun) {
    Write-Host 'REZHIM PROVORKI: nichego ne budet zapisano.' -ForegroundColor Yellow
    Write-Host ''
}

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$DISPLAY_CLASS = '{4d36e968-e325-11ce-bfc1-08002be10318}'
$VENDORS = @{ nvidia = '10DE'; amd = '1002'; intel = '8086' }

$script:Ok = 0
$script:Failed = 0

# ============================================================== обнаружение ===

function Get-DisplayAdapters {
    $found = @()
    $enumBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
    if (-not (Test-Path -LiteralPath $enumBase)) { return $found }

    foreach ($hw in Get-ChildItem -LiteralPath $enumBase -ErrorAction SilentlyContinue) {
        if ($hw.PSChildName -notmatch '^VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
        $vendorId = $Matches[1].ToUpper()
        $deviceId = $Matches[2].ToUpper()

        foreach ($inst in Get-ChildItem -LiteralPath $hw.PSPath -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $inst.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DeviceDesc) { continue }
            # берём только настоящие видеоадаптеры, а не программные (WARP и т.п.)
            if ("$($p.ClassGUID)" -ne $DISPLAY_CLASS) { continue }
            if (-not $p.Driver) { continue }

            $found += [pscustomobject]@{
                VendorId = $vendorId
                DeviceId = $deviceId
                HwId     = $hw.PSChildName
                Instance = $inst.PSChildName
                EnumPath = $inst.PSPath
                ClassKey = $p.Driver
                Name     = (("$($p.DeviceDesc)" -split ';')[-1]).Trim()
            }
        }
    }
    return $found
}

function Show-Adapters {
    param([array]$List)
    if (-not $List -or $List.Count -eq 0) {
        Write-Host '  (net)' -ForegroundColor DarkGray
        return
    }
    Write-Host ("  {0,-4} {1,-9} {2,-9} {3}" -f '#','VEN:DEV','class','.NET devichestvo') -ForegroundColor DarkGray
    for ($n = 0; $n -lt $List.Count; $n++) {
        $a = $List[$n]
        Write-Host ("  {0,-4} {1,-9} {2,-9} {3}" -f ($n+1), "$($a.VendorId):$($a.DeviceId)", ($a.ClassKey -replace '.*\\',''), $a.Name) -ForegroundColor White
    }
}

$adapters = @(Get-DisplayAdapters)

Write-Host "Cel: '$GpuName' / $VramGB GB" -ForegroundColor Green
Write-Host ''
Write-Host '=== NAKHODENNIE VIDEOADAPTERY ===' -ForegroundColor Cyan
Show-Adapters $adapters

if ($adapters.Count -eq 0) {
    Write-Host 'Videoadapterov klassa Display ne naydeno.' -ForegroundColor Red
    Write-Host 'Esli eto virtualnaya/VGA- kartochka - skript ee ne trogaet.' -ForegroundColor Yellow
    Read-Host 'Nazmi Enter'; exit 1
}

# ---------- фильтр по вендору ----------
$candidates = $adapters
if ($Vendor -ne 'auto' -and $Vendor -ne 'any') {
    $want = $VENDORS[$Vendor]
    $candidates = @($adapters | Where-Object { $_.VendorId -eq $want })
    if ($candidates.Count -eq 0) {
        Write-Host "Kartochek proizvoditelya '$Vendor' (VEN_$want) ne naydeno." -ForegroundColor Red
        Read-Host 'Nazmi Enter'; exit 1
    }
    Write-Host "Filtr: $Vendor -> $($candidates.Count)" -ForegroundColor DarkGray
}

# ---------- выбор адаптера ----------
if ($All) {
    $targets = $candidates
    if ($targets.Count -gt 1) {
        Write-Host ''
        Write-Host 'VNIMANIE - pereimenovyvayutsya VSE adaptory:' -ForegroundColor Yellow
        Show-Adapters $targets
        Write-Host 'Na ноутbukakh vstroennaya grafika tozhe sdelaet «RTX 5090».' -ForegroundColor Yellow
        if (-not (Read-Host 'Prodolzhit? (y/n)') -match '^(y|yes|д|да)$') { exit 0 }
    }
} elseif ($Index -gt 0) {
    if ($Index -gt $candidates.Count) { Write-Host "Nomer $Index vne diapazona 1..$($candidates.Count)" -ForegroundColor Red; exit 1 }
    $targets = @($candidates[$Index - 1])
} elseif ($candidates.Count -eq 1) {
    $targets = $candidates
} else {
    Write-Host ''
    Write-Host 'Naydeno bolshe odnoy kartochki. Viberi nomer (0 = otmenit):' -ForegroundColor Yellow
    Show-Adapters $candidates
    $choice = Read-Host 'Nomer'
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
        $targets = @($candidates[$n - 1])
    } else {
        Write-Host 'Otmeneno.' -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ''
Write-Host "Obrabatyvaem: $($targets[0].Name)  [$($targets[0].VendorId):$($targets[0].DeviceId)]" -ForegroundColor Cyan

# ============================================================== вспомогательное ===

function Set-RegVal {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if ($DryRun) {
        Write-Host ("      {0,-34} = {1}   [bylo by: dry-run]" -f $Name, $Value) -ForegroundColor DarkCyan
        $script:Ok++
        return $true
    }
    try {
        if ($null -ne (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) {
            Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -ErrorAction Stop
        } else {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        Write-Host ("      {0,-34} = {1}" -f $Name, $Value) -ForegroundColor DarkGreen
        $script:Ok++
        return $true
    } catch {
        Write-Host ("      {0,-34} ! {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
        return $false
    }
}

# Ключи Enum\PCI*\... защищены: писать в них может только SYSTEM.
#
# ВАЖНО: здесь нужно именно -Path, а не -LiteralPath.
# Get-Acl -LiteralPath падает с ItemNotFoundException на путях реестра,
# содержащих '&', а во всех ключах Enum\PCI он есть по построению:
#   VEN_10DE&DEV_2187&SUBSYS_8D951462&REV_A1
# При этом Get-ItemProperty/Set-ItemProperty -LiteralPath работают нормально -
# ломается только работа с дескрипторами безопасности.
function Unlock-Key {
    param([string]$Path)
    if ($DryRun) { return $true }

    $acl = $null
    try {
        $acl = Get-Acl -Path $Path -ErrorAction Stop
    } catch {
        Write-Host "      (ne udalos prochitatat ACL: $($_.Exception.Message))" -ForegroundColor DarkYellow
        return $false
    }
    if (-not $acl) {
        Write-Host '      (ACL = NULL, propuskayu razblokirovku)' -ForegroundColor DarkYellow
        return $false
    }

    try {
        # забираем владение себе, иначе Set-Acl может не хватить прав
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($acl.Owner -ne $me) {
            try { $acl.SetOwner([System.Security.Principal.NTAccount]$me) } catch { }
        }
        $acl.SetAccessRuleProtection($false, $true)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            'BUILTIN\Administrators',
            [System.Security.AccessControl.RegistryRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
            ([System.Security.AccessControl.PropagationFlags]::None),
            ([System.Security.AccessControl.AccessControlType]::Allow))
        $acl.SetAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        Write-Host "      (unlock failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
        return $false
    }
}

function Patch-GpuKey {
    param([string]$Path, [long]$Bytes, [string]$Label)

    # Формат настоящего драйвера: qwMemorySize = точный размер,
    # MemorySize = размер - 1 МБ, обрезанный до 32 бит.
    #
    # НЕЛЬЗЯ писать ($Bytes - 0x100000) -band 0xFFFFFFFF:
    # в PowerShell 5.1 литерал 0xFFFFFFFF разбирается как Int32 -1,
    # а не как 4294967295, поэтому -band ничего не обрезает и [uint32] падает.
    # Обрезаем по модулю.
    $dw = [uint32](($Bytes - 0x100000) % [long]4294967296)

    Write-Host "  [$Label]" -ForegroundColor Cyan
    Set-RegVal $Path 'DriverDesc'                        'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.AdapterString' 'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.ChipType'     'String' $GpuName | Out-Null
    Set-RegVal $Path 'HardwareInformation.qwMemorySize' 'QWord'  ([uint64]$Bytes) | Out-Null
    Set-RegVal $Path 'HardwareInformation.MemorySize'   'DWord'  $dw | Out-Null
}

function Find-VideoKeys {
    # MatchingDeviceId имеет вид pci\ven_10de&dev_2187&subsys_8d951462,
    # поэтому сравниваем по префиксу, а не точным равенством.
    # Таких подключей обычно несколько (0000..000N) - все от одной карты,
    # и Windows может использовать любой, поэтому патчим их все.
    param([string]$VendorId, [string]$DeviceId)
    $prefix = 'pci\ven_' + $VendorId.ToLower() + '&dev_' + $DeviceId.ToLower()
    @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Video' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object {
            $m = (Get-ItemProperty -LiteralPath $_.PSPath -Name 'MatchingDeviceId' -ErrorAction SilentlyContinue).MatchingDeviceId
            $m -and $m.StartsWith($prefix)
        })
}

$bytes = [long]($VramGB * 1GB)

# ============================================================== патчинг ===

$n = 0
foreach ($t in $targets) {
    $n++
    Write-Host ''
    Write-Host "### [$n] $($t.Name)" -ForegroundColor White

    # --- 1. ключ класса ---
    $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($t.ClassKey)"
    if (Test-Path -LiteralPath $classPath) {
        $regFile = Join-Path $backupDir "class-$($t.ClassKey -replace '.*\\','')-$($t.DeviceId)-$stamp.reg"
        & reg.exe export ($classPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE','HKLM') $regFile /y 2>$null | Out-Null
        Patch-GpuKey $classPath $bytes "Class\$($t.ClassKey -replace '.*\\','')"
    } else {
        Write-Host "  [Class] ne nayden: $classPath" -ForegroundColor Red
        $script:Failed++
    }

    # --- 2. Control\Video (обычно несколько подключей от одной карты) ---
    $vks = @(Find-VideoKeys $t.VendorId $t.DeviceId)
    if ($vks.Count -eq 0) {
        Write-Host '  [Video] klyuchi ne naydeny' -ForegroundColor DarkYellow
    } else {
        foreach ($vk in $vks) {
            $regFile = Join-Path $backupDir "video-$($t.DeviceId)-$($vk.PSChildName)-$stamp.reg"
            & reg.exe export ($vk.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE','HKLM') $regFile /y 2>$null | Out-Null
            Patch-GpuKey $vk.PSPath $bytes "Video\$($vk.PSChildName)"
        }
    }

    # --- 3. Enum\PCI ---
    Write-Host '  [Enum\PCI - Device Manager / dxdiag / WMI]' -ForegroundColor Cyan
    $regFile = Join-Path $backupDir ("enum-$($t.VendorId)-$($t.DeviceId)-$stamp.reg")
    & reg.exe export ($t.EnumPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE','HKLM') $regFile /y 2>$null | Out-Null
    Unlock-Key $t.EnumPath | Out-Null

    $cur = (Get-ItemProperty -LiteralPath $t.EnumPath -Name 'DeviceDesc' -ErrorAction SilentlyContinue).DeviceDesc
    $infRef = $null; $infToken = $null
    # формат:  @oem4.inf,%token%;Отображаемое имя
    # Ведущий '@' обязателен - он помечает значение как ссылку на INF.
    if ($cur -match '^@([^,]+),([^;]+);(.*)$') {
        $infRef = $Matches[1]; $infToken = $Matches[2].Trim('%')
        $new = '@' + $Matches[1] + ',' + $Matches[2] + ';' + $GpuName
    } else {
        $new = $GpuName
    }
    Set-RegVal $t.EnumPath 'DeviceDesc' 'String' $new | Out-Null
    if ($null -ne (Get-ItemProperty -LiteralPath $t.EnumPath -Name 'FriendlyName' -ErrorAction SilentlyContinue)) {
        Set-RegVal $t.EnumPath 'FriendlyName' 'String' $GpuName | Out-Null
    }

    # --- 4. INF ---
    if ($infRef -and $infToken) {
        Write-Host "  [INF: $infRef / $infToken]" -ForegroundColor Cyan
        $infPath = Join-Path $env:SystemRoot "INF\$infRef"
        if (Test-Path -LiteralPath $infPath) {
            Copy-Item -LiteralPath $infPath -Destination (Join-Path $backupDir "$infRef.bak") -Force
            # файл драйвера - ASCII без BOM, любая ASCII-кодировка даёт
            # побайтово идентичный результат
            $txt  = [IO.File]::ReadAllText($infPath, [Text.Encoding]::ASCII)
            $rx   = [regex]::new('(?im)^(' + [regex]::Escape($infToken) + '\s*=\s*)"[^"]*"')
            if ($rx.IsMatch($txt)) {
                if (-not $DryRun) {
                    [IO.File]::WriteAllText($infPath, $rx.Replace($txt, '${1}"' + $GpuName + '"'), [Text.Encoding]::ASCII)
                }
                Write-Host ("      {0} -> {1}{2}" -f $infToken, $GpuName, $(if ($DryRun) { '   [dry-run]' } else { '' })) -ForegroundColor DarkGreen
                $script:Ok++
            } else {
                Write-Host "      token '$infToken' ne najden v INF" -ForegroundColor Red
                $script:Failed++
            }
        } else {
            Write-Host "      $infPath ne nayden" -ForegroundColor Red
            $script:Failed++
        }
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