#Requires -Version 5.1
<#  check.ps1 - показывает, что система сообщает о видеокарте на всех поверхностях #>

$ErrorActionPreference = 'Continue'
$FAKE = 'NVIDIA GeForce RTX 5090'
$DISPLAY_CLASS = '{4d36e968-e325-11ce-bfc1-08002be10318}'

function Line($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

Write-Host "Vremya: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("Apteim: {0:N1} min (zagruzka v {1})" -f ((Get-Date) - $os.LastBootUpTime).TotalMinutes, $os.LastBootUpTime.ToString('HH:mm:ss'))

# ---------- найти адаптеры класса Display ----------
$found = @()
foreach ($hw in Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue) {
    if ($hw.PSChildName -notmatch '^VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { continue }
    $v = $Matches[1].ToUpper(); $d = $Matches[2].ToUpper()
    foreach ($inst in Get-ChildItem -LiteralPath $hw.PSPath -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty -LiteralPath $inst.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.DeviceDesc) { continue }
        if ("$($p.ClassGUID)" -ne $DISPLAY_CLASS) { continue }
        if (-not $p.Driver) { continue }
        $found += [pscustomobject]@{
            VendorId = $v; DeviceId = $d; ClassKey = $p.Driver; EnumPath = $inst.PSPath
            EnumDesc = (("$($p.DeviceDesc)" -split ';')[-1]).Trim()
        }
    }
}

Line '1. NAKHODENNIE ADAPTERY (klass Display)'
if ($found.Count -eq 0) { Write-Host '  net' -ForegroundColor Red }
else {
    Write-Host ("  {0,-10} {1,-30} {2}" -f 'VEN:DEV','klass klassa','imya v Enum') -ForegroundColor DarkGray
    foreach ($a in $found) {
        $hit = if ("$($a.EnumDesc)" -like '*5090*') { ' <-- PODMENA' } else { '' }
        Write-Host ("  {0,-10} {1,-30} {2}{3}" -f "$($a.VendorId):$($a.DeviceId)", ($a.ClassKey -replace '.*\\',''), $a.EnumDesc, $hit) -ForegroundColor $(if($hit){'Green'}else{'White'})
    }
}

Line '2. Klyuch klassa (realnye znacheniya v regresstre)'
foreach ($a in $found) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($a.ClassKey)"
    Write-Host "  [$($a.VendorId):$($a.DeviceId)]" -ForegroundColor Cyan
    foreach ($n in 'DriverDesc','HardwareInformation.AdapterString','HardwareInformation.qwMemorySize','HardwareInformation.MemorySize') {
        $p = Get-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue
        if ($p) {
            $val = $p.$n
            if ($n -match 'qwMemorySize') { $val = '{0}  ({1:N1} GB)' -f $val, ($val / 1GB) }
            Write-Host ("    {0,-34} = {1}" -f $n, $val) -ForegroundColor DarkGray
        } else { Write-Host ("    {0,-34} = <net>" -f $n) -ForegroundColor DarkGray }
    }
}

Line '3. SetupAPI - to, chto pokazyvaet Dispetcher ustroystv'
try {
    Get-PnpDevice -Class Display -ErrorAction Stop | ForEach-Object {
        $mark = if ("$($_.FriendlyName)" -like '*5090*') { ' <-- PODMENA' } else { '' }
        Write-Host ("  {0,-40}{1}" -f $_.FriendlyName, $mark) -ForegroundColor $(if($mark){'Green'}else{'Gray'})
    }
} catch { Write-Host "  oshibka: $($_.Exception.Message)" -ForegroundColor Red }

Line '4. WMI / Svoistva sistemy'
Get-CimInstance Win32_VideoController | ForEach-Object {
    $mark = if ("$($_.Name)" -like '*5090*') { ' <-- PODMENA' } else { '' }
    Write-Host ("  {0}  [{1}]{2}" -f $_.Name, $_.DriverVersion, $mark) -ForegroundColor $(if($mark){'Green'}else{'Gray'})
}

Line '5. DXGI / nvidia-sli - to, chto realno soobshchaet drayver'
$srcBin = Join-Path $PSScriptRoot 'src\out'
$nsmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $nsmi) { $p = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'; if (Test-Path $p) { $nsmi = Get-Item $p } }
if ($nsmi) {
    try {
        (& $nsmi.Source --query-gpu=name,memory.total --format=csv 2>&1 | Out-String).Trim() -split "`r?`n" |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        Write-Host '  (Eto VSEGDA nastoyashchee - chitaet pryamuyu iz NVAPI)' -ForegroundColor DarkYellow
    } catch { Write-Host "  oshibka: $($_.Exception.Message)" }
} else {
    Write-Host "  net nvidia-smi" -ForegroundColor DarkYellow
}

Line 'Itog'
$sp = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { "$($_.FriendlyName)" -like '*5090*' })
$wm = @(Get-CimInstance Win32_VideoController | Where-Object { "$($_.Name)" -like '*5090*' })
Write-Host ("  Dispetcher ustroystv : {0}" -f $(if ($sp.Count) { "PODMENA ($($sp.Count))" } else { 'poka ne primeneno' }))
Write-Host ("  WMI / O systeme      : {0}" -f $(if ($wm.Count) { "PODMENA ($($wm.Count))" } else { 'poka ne primeneno' }))
Write-Host "  Dispetcher zadach    : proveray glazami (imennya menyaetsya, pamyat - net)"
Write-Host "  Obem VRAM            : NE PODMENYAETSya, vsegda nastoyashchiy"
Write-Host ''
if ($sp -and $wm) { Write-Host 'REGISTRY CHAST RABOTAET.' -ForegroundColor Green }
else { Write-Host 'Nuzhna PEREZAGRUZKA - skript chitaetsya tolko pri inicializacii ustroystva.' -ForegroundColor Yellow }
Write-Host ''
Read-Host 'Nazmi Enter'