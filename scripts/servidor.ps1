# Arranca el servidor web del dispensador (Face ID -> FPGA).
# Uso:  .\scripts\servidor.ps1               # con la DE10-Lite conectada y programada
#       .\scripts\servidor.ps1 -Mock         # sin tarjeta: FPGA simulada en software
#       .\scripts\servidor.ps1 -Pin 123456   # fija el PIN de administrador
param(
    [switch]$Mock,
    [string]$Pin = "",
    [int]$Puerto = 5000,
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$raiz = Join-Path $PSScriptRoot ".."

& $Python -c "import flask, webauthn" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Instalando dependencias (flask, webauthn)..." -ForegroundColor Yellow
    & $Python -m pip install -r (Join-Path $raiz "server\requirements.txt")
}
if ($Pin) { $env:ADMIN_PIN = $Pin }

$argsSrv = @((Join-Path $raiz "server\app.py"), "--port", $Puerto)
if ($Mock) { $argsSrv += "--mock" }
& $Python @argsSrv
