#Requires -Version 5.1
<#
  RTX 5090 Scam Mode - ОТКАТ
  Восстанавливает оригинальные значения из последнего бэкапа в backup\.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath
$backupDir = Join-Path $scriptDir 'backup'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Nuzhny prava administratora. Perezapusk s povysheniem...' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File', ('"' + $PSCommandPath + '"'))
    exit
}

if (-not (Test-Path $backupDir)) { Write-Host 'Bekapov net - otkazyvat nechego.' -ForegroundColor Red; exit 1 }

function Import-Match {
    param([string]$Filter, [string]$Title)
    $files = Get-ChildItem $backupDir -Filter $Filter -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime
    if (-not $files) { Write-Host "  [$Title] - net bekapa" -ForegroundColor DarkYellow; return }
    Write-Host "  [$Title] $($files.Count) fayl(ov)" -ForegroundColor Cyan
    foreach ($f in $files) {
        & reg.exe import $f.FullName 2>&1 | Out-Null
        Write-Host "    $($f.Name)" -ForegroundColor DarkGray
    }
}

Write-Host 'OTKAT:' -ForegroundColor Yellow
Import-Match 'class-*.reg' 'Class'
Import-Match 'video-*.reg' 'Video'
Import-Match 'enum-*.reg'  'Enum'

Write-Host '  [INF]' -ForegroundColor Cyan
$infBaks = Get-ChildItem $backupDir -Filter '*.inf.bak' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
if ($infBaks) {
    $b = $infBaks[-1]
    $dest = Join-Path $env:SystemRoot "INF\$($b.Name -replace '\.bak$','')"
    Copy-Item -LiteralPath $b.FullName -Destination $dest -Force
    Write-Host "    vosstanovlen $($b.Name) -> $dest" -ForegroundColor DarkGreen
} else {
    Write-Host '    net kopii INF' -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host 'Gotovo. PerEZAGRUZI PK.' -ForegroundColor Green
Read-Host 'Nazmi Enter'