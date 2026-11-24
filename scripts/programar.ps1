# Carga dispensador.sof en la DE10-Lite por el cable USB-Blaster.
# La configuracion se pierde al desconectar la tarjeta; para dejarla fija usa -Flash
# (programa el .pof en la memoria interna del MAX 10).
# Uso:  .\scripts\programar.ps1
#       .\scripts\programar.ps1 -Flash
param(
    [string]$Quartus = "C:\altera_lite\25.1std\quartus\bin64",
    [switch]$Flash
)
$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "..\quartus\output_files"
$pgm = Join-Path $Quartus "quartus_pgm.exe"
$jtag = Join-Path $Quartus "jtagconfig.exe"
if (-not (Test-Path $pgm)) { throw "No encuentro $pgm. Indica la carpeta bin64 de Quartus con -Quartus." }

Write-Host "== Cables JTAG detectados ==" -ForegroundColor Cyan
& $jtag
$cable = "USB-Blaster [USB-0]"

if ($Flash) {
    $archivo = Join-Path $out "dispensador.pof"
    & $pgm -c $cable -m JTAG -o "p;$archivo"
} else {
    $archivo = Join-Path $out "dispensador.sof"
    & $pgm -c $cable -m JTAG -o "p;$archivo"
}
if ($LASTEXITCODE -ne 0) { throw "No se pudo programar la tarjeta. Revisa el cable y el driver del USB-Blaster." }
Write-Host "Listo: los displays deben mostrar 'id 0000'." -ForegroundColor Green
