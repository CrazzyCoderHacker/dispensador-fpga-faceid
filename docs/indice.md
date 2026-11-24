# Documentación del dispensador FPGA con Face ID

Proyecto final de **Sistemas Embebidos**, UDLAP, otoño 2026. Profesor: Dr. Gerardo Ulises Díaz Arango.

| Documento | Contenido |
|---|---|
| [Arquitectura](arquitectura.md) | Diagramas del sistema, flujo de Face ID, módulos de la FPGA, máquina de estados y alarmas |
| [Cómo correr el proyecto](como-correr.md) | Requisitos, simulación, compilar y programar, servidor, túnel e iPhone |
| [Protocolo JTAG](protocolo-jtag.md) | Formato de órdenes, códigos de resultado, mapa de la sonda y bitácora |
| [Tarjeta DE10-Lite](tarjeta-de10lite.md) | Switches, botones, displays, LEDs y GPIO |
| [Pruebas y resultados](pruebas-y-resultados.md) | Recursos, pruebas automáticas, fotos de la tarjeta y tiempos medidos |
| [Guion de la demostración](guion-demo.md) | Casos para presentar, paso a paso |
| [Reporte (PDF)](../reporte/reporte.pdf) | Reporte final del proyecto |

## Estructura del repositorio

```
rtl/        Verilog de la FPGA (12 módulos)
sim/        Bancos de prueba para Icarus Verilog y script run_all.sh
quartus/    Proyecto de Quartus (.qpf/.qsf/.sdc) y .sof/.pof compilados
server/     Servidor Flask: Face ID (WebAuthn) y puente JTAG con quartus_stp
scripts/    PowerShell para compilar, programar, servidor y túnel; demo guiada
docs/       Esta documentación
capturas/   Capturas de la página en cada caso de prueba
reporte/    Reporte en LaTeX, PDF e imágenes (fotos de la tarjeta y del iPhone)
```

## Inicio rápido

```powershell
bash sim/run_all.sh                    # 1. lógica de la FPGA en simulación
.\scripts\programar.ps1                # 2. cargar la FPGA (DE10-Lite por USB)
.\scripts\servidor.ps1 -Pin 123456     # 3. servidor conectado a la tarjeta
.\scripts\tunel.ps1                    # 4. HTTPS para el iPhone (otra terminal)
```
