#Requires -Version 5.1
<#
  RTX 5090 Scam Mode - ОТКАТ

  Восстанавливает оригинальные значения из backup\pristine\.

  Снимок оригинала делается один раз при первом запуске apply.ps1 и больше
  не перезаписывается, поэтому откат всегда возвращает систему в одно и то же
  состояние - независимо от того, сколько раз запускалась подмена.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath
$pristine  = Join-Path $scriptDir 'backup\pristine'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Nuzhny prava administratora. Perezapusk s povysheniem...' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"' + $PSCommandPath + '"'))
    exit
}

if (-not (Test-Path -LiteralPath $pristine)) {
    Write-Host 'NET ORIGINALNOGO SNIMKA' -ForegroundColor Red
    Write-Host ''
    Write-Host "Ozhidaetsya: $pristine" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Eto znachit, chto 1_POSTAVIT_5090.cmd eshche ne zapuskalsya' -ForegroundColor Yellow
    Write-Host 'ili snimok udalen. Bez nego otkat vozmozhen tolko vruchnuyu:' -ForegroundColor Yellow
    Write-Host '  - Dispetcher ustroystv -> GPU -> Svoistva -> Odin iz ustroystv -> Udali' -ForegroundColor DarkGray
    Write-Host '  - perezagruzit PK, Windows perechitaet INF drayvera' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host 'Nazmi Enter'
    exit 1
}

$regs = @(Get-ChildItem -LiteralPath $pristine -Filter '*.reg' -ErrorAction SilentlyContinue)
if ($regs.Count -eq 0) {
    Write-Host 'V papke snimkov net .reg faylov.' -ForegroundColor Red
    Read-Host 'Nazmi Enter'; exit 1
}

Write-Host 'VOZVRASHCHAYU ORIGINALNOE SOSTOYANIE:' -ForegroundColor Yellow
Write-Host ''

foreach ($f in $regs) {
    $out = & reg.exe import $f.FullName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  [+] {0}" -f $f.Name) -ForegroundColor DarkGreen
    } else {
        Write-Host ("  [!] {0} - import ne udalsya" -f $f.Name) -ForegroundColor Red
        if ($out) { Write-Host "      $out" -ForegroundColor DarkRed }
    }
}

Write-Host ''
Write-Host '  [INF]' -ForegroundColor Cyan
$infs = @(Get-ChildItem -LiteralPath $pristine -Filter '*.inf' -ErrorAction SilentlyContinue)
if ($infs.Count -eq 0) {
    Write-Host '    snimka INF net' -ForegroundColor DarkYellow
} else {
    foreach ($b in $infs) {
        $dest = Join-Path $env:SystemRoot "INF\$($b.Name)"
        try {
            Copy-Item -LiteralPath $b.FullName -Destination $dest -Force -ErrorAction Stop
            Write-Host ("    [+] {0} -> {1}" -f $b.Name, $dest) -ForegroundColor DarkGreen
        } catch {
            Write-Host ("    [!] {0} - {1}" -f $b.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host 'Gotovo. Puzhdaetsya PEREZAGRUZKA.' -ForegroundColor Green
Write-Host 'Bez nee Windows mozhet derzhat staroe opisanie v keshe.' -ForegroundColor Yellow
Write-Host ''
Read-Host 'Nazmi Enter'