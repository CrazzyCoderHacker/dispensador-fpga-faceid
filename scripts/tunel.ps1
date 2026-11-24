# Publica el servidor local por HTTPS para abrirlo desde el iPhone.
# Face ID (WebAuthn) solo funciona con HTTPS y un nombre de dominio, no con una IP.
# Usa un "Quick Tunnel" gratuito de Cloudflare (no requiere cuenta).
# Instalar cloudflared una sola vez:  winget install --id Cloudflare.cloudflared
# Uso:  .\scripts\tunel.ps1            (con el servidor ya corriendo en el puerto 5000)
param([int]$Puerto = 5000)
$ErrorActionPreference = "Stop"

$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) {
    foreach ($p in "C:\Program Files (x86)\cloudflared\cloudflared.exe", "C:\Program Files\cloudflared\cloudflared.exe") {
        if (Test-Path $p) { $cf = $p; break }
    }
}
if (-not $cf) { throw "No encuentro cloudflared. Instalalo con: winget install --id Cloudflare.cloudflared" }

Write-Host "Busca abajo la linea https://....trycloudflare.com y abrela en Safari del iPhone." -ForegroundColor Cyan
Write-Host "La direccion cambia cada vez: las caras se registran de nuevo en cada direccion." -ForegroundColor Yellow
& $cf tunnel --no-autoupdate --url "http://localhost:$Puerto"
