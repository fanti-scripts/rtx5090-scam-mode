<#
  build.ps1 - собирает нативные части проекта.

  Требуется Visual Studio 2022 (или Build Tools) с компонентами:
    - MSVC v143 x64/x86
    - Windows 10/11 SDK

  Если vswhere.exe есть в стандартном месте, путь к vcvarsall.bat
  находится автоматически, иначе укажи его параметром -VcVars.
#>
[CmdletBinding()]
param([string]$VcVars)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$out  = Join-Path $here 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# ---------- найти vcvarsall.bat ----------
if (-not $VcVars) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $inst = & $vswhere -latest -products * `
                    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                    -property installationPath 2>$null
        if ($inst) { $VcVars = Join-Path $inst 'VC\Auxiliary\Build\vcvarsall.bat' }
    }
}
if (-not $VcVars) {
    $guess = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat" `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($guess) { $VcVars = $guess.FullName }
}

if (-not $VcVars -or -not (Test-Path $VcVars)) {
    Write-Host 'NE NAIDEN vcvarsall.bat.' -ForegroundColor Red
    Write-Host 'Postavi Visual Studio 2022 / Build Tools s komponentomami "MSVC v143" i "Windows SDK".' -ForegroundColor Yellow
    Write-Host 'Ili peredaj put explicitno: .\build.ps1 -VcVars "C:\...\VC\Auxiliary\Build\vcvarsall.bat"' -ForegroundColor Yellow
    exit 1
}
Write-Host "vcvarsall: $VcVars" -ForegroundColor DarkGray

# ---------- gpuinfo: читает адаптеры через DXGI ----------
Write-Host '>>> gpuinfo' -ForegroundColor Cyan
$cmd = "`"$VcVars`" x64 >nul 2>&1 && cd /d `"$here`" && cl /nologo /EHsc /std:c++17 /O2 /W3 gpuinfo.cpp /Fe:gpuinfo.exe /link dxgi.lib user32.lib"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { Write-Host 'sborka gpuinfo ne udalas' -ForegroundColor Red; exit 1 }

# ---------- test_dxgi: стенд для проверки прокси ----------
Write-Host '>>> test_dxgi' -ForegroundColor Cyan
$cmd = "`"$VcVars`" x64 >nul 2>&1 && cd /d `"$here`" && cl /nologo /EHsc /std:c++17 /O2 /W3 test_dxgi.cpp /Fe:test_dxgi.exe /link /ENTRY:wmainCRTStartup user32.lib"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { Write-Host 'sborka test_dxgi ne udalas' -ForegroundColor Red; exit 1 }

# ---------- dxgi_proxy: экспериментальная DLL-прокси ----------
Write-Host '>>> dxgi_proxy' -ForegroundColor Cyan
$cmd = "`"$VcVars`" x64 >nul 2>&1 && cd /d `"$here`" && cl /nologo /LD /EHsc /std:c++17 /O2 /W3 dxgi_proxy.cpp /Fe:dxgi.dll /link /DEF:dxgi_proxy.def user32.lib"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { Write-Host 'sborka dxgi_proxy ne udalas' -ForegroundColor Red; exit 1 }

Move-Item (Join-Path $here 'gpuinfo.exe')    $out -Force -ErrorAction SilentlyContinue
Move-Item (Join-Path $here 'test_dxgi.exe') $out -Force -ErrorAction SilentlyContinue
Move-Item (Join-Path $here 'dxgi.dll')      $out -Force -ErrorAction SilentlyContinue

Get-ChildItem $here -Filter '*.obj' | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $here 'dxgi.exp') (Join-Path $here 'dxgi.lib') -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Gotovo. Rezultaty v $out" -ForegroundColor Green