# Cómo correr el proyecto

Hay cuatro formas de probarlo, de menos a más hardware:

| Modo | Necesitas | Para qué |
|---|---|---|
| [1. Simulación del Verilog](#1-simulación-del-verilog) | Icarus Verilog | Verificar la lógica de la FPGA sin tarjeta |
| [2. Página con FPGA simulada](#2-página-con-fpga-simulada---mock) | Python | Ver la interfaz y probar Face ID sin tarjeta |
| [3. Tarjeta real](#3-tarjeta-real) | Quartus + DE10-Lite | El sistema completo desde la laptop |
| [4. Face ID desde el iPhone](#4-face-id-desde-el-iphone) | + cloudflared + iPhone | La demostración completa |

Los comandos son para **Windows**; los scripts de [scripts/](../scripts) son de PowerShell.

---

## Requisitos

| Herramienta | Versión probada | Instalación |
|---|---|---|
| Quartus Prime **Lite** + soporte **MAX 10** | 25.1std | altera.com → *Downloads* → *Quartus Prime Lite Edition* (requiere cuenta gratuita). En el instalador marca solo *Quartus Prime* y *MAX 10 FPGA device support*, más *Install drivers* para el USB-Blaster |
| Python | 3.11 | [python.org](https://www.python.org/downloads/) |
| Flask, webauthn | 3.1, 3.0 | `python -m pip install -r server/requirements.txt` |
| Icarus Verilog (solo simulación) | 11.0 | `choco install iverilog` o [instaladores para Windows](https://bleyer.org/icarus/) |
| cloudflared (solo iPhone) | 2026.11 | `winget install --id Cloudflare.cloudflared` |
| Git Bash | — | Para `bash sim/run_all.sh` (viene con [Git para Windows](https://git-scm.com/download/win)) |

---

## 1. Simulación del Verilog

```bash
bash sim/run_all.sh
```

Compila cada banco de pruebas con `rtl/*.v` y un modelo del bloque JTAG ([sim/altsource_probe_stub.v](../sim/altsource_probe_stub.v)). En la prueba de sistema, el banco hace el papel de la laptop: escribe órdenes en el registro *source* y lee el *probe* con el mismo mapa de bits que el servidor.

Salida esperada:

```
tb_divu RESULT: PASS 205 FAIL 0
tb_bolus_limiter RESULT: PASS 10 FAIL 0
tb_infusion_ctrl RESULT: PASS 20 FAIL 0
tb_system RESULT: PASS 33 FAIL 0
TODAS LAS PRUEBAS PASARON
```

Las bitácoras de cada prueba quedan en `sim/build/*.log`.

---

## 2. Página con FPGA simulada (`--mock`)

```powershell
.\scripts\servidor.ps1 -Mock -Pin 123456
```

Abre <http://localhost:5000>. `MockBridge` imita la FPGA en software, así que se puede recorrer toda la página. En `localhost` el navegador de la laptop permite WebAuthn, así que también se pueden registrar caras con Windows Hello o una llave de seguridad.

Pruebas automáticas del servidor (WebAuthn con un autenticador de software P-256):

```powershell
python server/test_server.py
```

```
test_server RESULT: PASS 29 FAIL 0
```

---

## 3. Tarjeta real

### 3.1 Compilar (opcional)

El repositorio ya incluye [quartus/output_files/dispensador.sof](../quartus/output_files/dispensador.sof) compilado. Para volver a compilarlo:

```powershell
.\scripts\compilar.ps1
```

O desde la interfaz: abre `quartus/dispensador.qpf` y presiona **Start Compilation**. Resultado esperado: 0 errores, ~2,600 elementos lógicos (5 %) y Fmax ≈ 72.8 MHz.

### 3.2 Programar la FPGA

Conecta la DE10-Lite por USB y ejecuta:

```powershell
.\scripts\programar.ps1
```

O en Quartus: **Tools → Programmer → Hardware Setup: USB-Blaster → Add File (`dispensador.sof`) → Start**. Los displays deben mostrar `id 0000` y LEDR8 debe parpadear.

> Con `.sof` la configuración se pierde al desconectar la tarjeta. `.\scripts\programar.ps1 -Flash` graba el `.pof` en la memoria interna para que la tarjeta arranque sola.

### 3.3 Arrancar el servidor

```powershell
.\scripts\servidor.ps1 -Pin 123456
```

El servidor busca `quartus_stp` en el `PATH` o en `C:\altera_lite\25.1std\quartus\bin64`. Si Quartus está en otra carpeta, define `QUARTUS_STP` o usa `python server/app.py --quartus-stp "ruta\quartus_stp.exe"`.

```
============================================================
 Dispensador FPGA  |  modo: DE10-Lite por JTAG
 PIN de administrador para registrar caras: 123456
 Abre http://localhost:5000 (o la URL https del tunel en el iPhone)
============================================================
```

Si sale `No pude hablar con la DE10-Lite`, revisa que la tarjeta esté conectada y programada, y que no haya otra ventana de Quartus usando el USB-Blaster (por ejemplo, el editor de In-System Sources and Probes abierto).

---

## 4. Face ID desde el iPhone

WebAuthn exige **HTTPS con nombre de dominio**; con la IP de la laptop no funciona. Con el servidor del paso 3 corriendo, abre otra terminal:

```powershell
.\scripts\tunel.ps1
```

cloudflared imprime una dirección como `https://palabras-al-azar.trycloudflare.com`. Ábrela en **Safari** del iPhone, con datos o con cualquier Wi-Fi.

1. **Registrar caras:** al final de la página, en *Registrar una cara (administrador)*:
   - **Enfermera:** nombre, rol *Enfermera*, ID **1–49**, PIN.
   - **Paciente:** rol *Paciente*, ID **50–99**.

   El iPhone pide guardar una passkey con Face ID.
2. **Entrar con Face ID** (enfermera) → LEDR0 se enciende en la tarjeta.
3. Cargar el programa eligiendo al paciente, **Iniciar** y probar los casos de [guion-demo.md](guion-demo.md).

Notas:

- Si al tocar *Entrar con Face ID* el iPhone ofrece "escanear código QR / llave de seguridad", todavía no hay una cara registrada en esa dirección. La página avisa de este caso.
- Si al registrar aparece lo mismo, activa el llavero de iCloud: *Ajustes → [tu nombre] → iCloud → Contraseñas*.
- La dirección del túnel **cambia cada vez** que se reinicia cloudflared. Las passkeys quedan ligadas al dominio, así que hay que registrar las caras de nuevo. Para la presentación, levanta el túnel una sola vez.

---

## 5. Sesión de fotos o demostración guiada (opcional)

[scripts/demo_capturas.py](../scripts/demo_capturas.py) arranca el servidor real y un control local que lleva la FPGA a cada caso y guarda la captura de la página en `capturas/`:

```powershell
python scripts/demo_capturas.py
curl http://127.0.0.1:5001/step/inactivo
curl http://127.0.0.1:5001/step/infusion
curl http://127.0.0.1:5001/step/llave
```

Casos: `inactivo, programa, infusion, bolos, rechazos, llave, tapado, gabinete, atender, pausa, fin`. El control solo escucha en `127.0.0.1`, así que no es accesible desde el túnel.

---

## 6. Reporte

El reporte está en [reporte/reporte.pdf](../reporte/reporte.pdf). Para recompilarlo desde [reporte/reporte.tex](../reporte/reporte.tex) con [Tectonic](https://tectonic-typesetting.github.io/):

```powershell
tectonic -X compile reporte\reporte.tex
```

También se puede subir `reporte.tex` y la carpeta `img/` a Overleaf (compilador XeLaTeX).
