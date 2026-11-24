# Compila el proyecto de Quartus (analisis, sintesis, fitter, ensamblador y tiempos).
# Uso:  .\scripts\compilar.ps1
#       .\scripts\compilar.ps1 -Quartus "D:\intelFPGA_lite\25.1std\quartus\bin64"
param(
    [string]$Quartus = "C:\altera_lite\25.1std\quartus\bin64"
)
$ErrorActionPreference = "Stop"
$proyecto = Join-Path $PSScriptRoot "..\quartus"
$sh = Join-Path $Quartus "quartus_sh.exe"
if (-not (Test-Path $sh)) { throw "No encuentro $sh. Indica la carpeta bin64 de Quartus con -Quartus." }

Push-Location $proyecto
try {
    & $sh --flow compile dispensador
    if ($LASTEXITCODE -ne 0) { throw "La compilacion fallo (codigo $LASTEXITCODE)." }
    Write-Host ""
    Write-Host "== Recursos ==" -ForegroundColor Cyan
    Get-Content output_files\dispensador.fit.summary | Select-String "Total logic|registers|Total pins"
    Write-Host "== Archivo para programar: quartus\output_files\dispensador.sof ==" -ForegroundColor Green
} finally {
    Pop-Location
}
