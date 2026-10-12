#Requires -Version 5.1
<#  check.ps1 - показывает, что система сообщает о видеокарте на всех поверхностях #>

$ErrorActionPreference = 'Continue'
$FAKE = 'NVIDIA GeForce RTX 5090'

function Line($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

Write-Host "Время: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
$up = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Host ("Аптайм: {0:N1} мин (загрузка в {1})" -f $up.TotalMinutes, (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('HH:mm:ss'))

Line '1. Реестр (фактические значения)'
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
foreach ($n in 'DriverDesc','HardwareInformation.AdapterString','HardwareInformation.qwMemorySize','HardwareInformation.MemorySize') {
    $p = Get-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue
    if ($p) {
        $v = $p.$n
        if ($n -match 'qwMemorySize') { $v = '{0}  ({1:N1} ГБ)' -f $v, ($v / 1GB) }
        Write-Host ("  {0,-34} = {1}" -f $n, $v) -ForegroundColor DarkGray
    } else { Write-Host ("  {0,-34} = <нет>" -f $n) -ForegroundColor DarkGray }
}

Line '2. SetupAPI - то, что показывает Диспетчер устройств'
try {
    Get-PnpDevice -Class Display -ErrorAction Stop | ForEach-Object {
        $mark = if ("$($_.FriendlyName)" -like '*5090*') { 'ПОДМЕНА' } else { '' }
        Write-Host ("  {0,-40} {1}" -f $_.FriendlyName, $mark) -ForegroundColor $(if($mark){'Green'}else{'Gray'})
    }
} catch { Write-Host "  ошибка: $($_.Exception.Message)" }

Line '3. WMI / Свойства системы'
Get-CimInstance Win32_VideoController | ForEach-Object {
    Write-Host ("  {0}  [{1}]" -f $_.Name, $_.DriverVersion)
}

Line '4. DXGI - то, что показывает Диспетчер задач'
$gpuinfo = Join-Path $PSScriptRoot 'tools\gpuinfo.exe'
if (Test-Path $gpuinfo) {
    # запускаем из отдельной папки, чтобы рядом не оказалась наша прокси-dxgi.dll
    $tmp = Join-Path $env:TEMP ('gpuinfo_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Copy-Item $gpuinfo $tmp -Force
    & (Join-Path $tmp 'gpuinfo.exe') | Out-String | Write-Host
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
} else { Write-Host "  нет gpuinfo.exe" }

Line 'Итог'
$reg  = (Get-ItemProperty -LiteralPath $k -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
$pnp  = (Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*NVIDIA*' }).FriendlyName
Write-Host "  Реестр           : $reg"
Write-Host "  Диспетчер устр.  : $pnp"
Write-Host ''
if ("$reg" -like '*5090*' -and "$pnp" -like '*5090*') {
    Write-Host 'РЕЕСТР + ДИСПЕТЧЕР УСТРОЙСТВ: подмена работает.' -ForegroundColor Green
} elseif ("$reg" -like '*5090*') {
    Write-Host 'Реестр изменён, но Диспетчер устройств ещё не подхватил.' -ForegroundColor Yellow
    Write-Host 'Нужна ПЕРЕЗАГРУЗКА (или отключить/включить видеоадаптер).' -ForegroundColor Yellow
} else {
    Write-Host 'Реестр не изменён - запусти 1_POSTAVIT_5090.cmd' -ForegroundColor Red
}
Write-Host ''
Read-Host 'Nazmi Enter'