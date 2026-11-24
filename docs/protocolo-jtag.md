# Protocolo laptop ↔ FPGA por JTAG

La laptop y la FPGA se comunican con el bloque **In-System Sources and Probes** (`altsource_probe`) de Quartus. Este bloque agrega al diseño dos registros accesibles por la cadena JTAG del USB-Blaster:

- **source (32 bits):** la laptop escribe la orden.
- **probe (224 bits):** la laptop lee el estado completo de la FPGA.

El servidor ([server/fpga_bridge.py](../server/fpga_bridge.py)) mantiene abierto `quartus_stp -s` y le envía estos comandos Tcl:

```tcl
set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw
write_source_data -instance_index 0 -value_in_hex -value 01100003   ;# orden
read_probe_data   -instance_index 0 -value_in_hex                    ;# estado
end_insystem_source_probe
```

Una lectura completa del estado tarda unos **7 ms** en la tarjeta real.

## Formato de la orden (source, 32 bits)

```
 31        24 23    20 19                                   0
+------------+--------+--------------------------------------+
|    seq     |   op   |                 arg                  |
+------------+--------+--------------------------------------+
```

- **seq:** número de secuencia. La FPGA ejecuta la orden cuando `seq` cambia y la palabra permanece estable dos muestras seguidas (sincronizada con 3 registros). Así una escritura a medias nunca se ejecuta y una orden nunca se repite.
- **op:** operación (tabla abajo).
- **arg:** `LOGIN`/`BOLO` llevan el ID en `[7:0]`; `SET` lleva el parámetro en `[19:17]` y el valor en `[9:0]`; `SIM` lleva las fallas en `[2:0]`.

| op | Orden | Regla aplicada en la FPGA |
|---|---|---|
| 1 | `LOGIN(id)` | Solo IDs 1–49 (enfermería) abren sesión; dura 120 s y se renueva con cada orden |
| 2 | `LOGOUT` | Cierra la sesión activa |
| 3 | `SET(sel, valor)` | Requiere sesión y valor dentro de rango (tabla de parámetros) |
| 4 | `START` | Requiere sesión y un programa válido |
| 5 | `C` (pausa / atender) | Pausar siempre se permite; atender alarma o "bolsa nueva" requiere sesión |
| 6 | `BOLO(id)` | El ID debe ser el del paciente asignado; después decide `bolus_limiter` |
| 7 | `SIM(fallas)` | **Solo demostración.** Bits `{gabinete, tubo tapado, llave}`; no otorga permisos |

### Parámetros de `SET`

| sel | Parámetro | Rango aceptado |
|---|---|---|
| 0 | Velocidad (mL/h) | 1–999 |
| 1 | Volumen a infundir (mL) | 1–999 |
| 2 | Bolo (mL) | 0–50 (0 = sin bolos) |
| 3 | Bloqueo entre bolos (min) | 0–240 |
| 4 | Bolos máximos por hora | 0–8 |
| 5 | ID del paciente asignado | 0 (ninguno) o 50–99 |

El campo de valor tiene 10 bits, así que el servidor rechaza antes de enviar cualquier valor mayor a 1023. Sin esa comprobación, un 2000 llegaría a la FPGA truncado a 976; este error se encontró y se corrigió en las pruebas con la tarjeta real.

### Códigos de resultado

| Código | Significado |
|---|---|
| 0 | Aceptada |
| 1 | El ID no es de enfermería |
| 2 | No hay sesión de enfermería |
| 3 | Valor fuera de rango |
| 4 | El rostro no corresponde al paciente asignado |
| 5 | Orden desconocida |

## Mapa del estado (probe, 224 bits)

| Bits | Campo | Bits | Campo |
|---|---|---|---|
| `[7:0]` | `ack_seq` (última orden atendida) | `[83:76]` | ID del paciente asignado |
| `[11:8]` | código de resultado | `[91:84]` | minutos de bloqueo restantes |
| `[14:12]` | estado (0 IDLE, 1 RUN, 2 PAUSE, 3 ALARM, 4 DONE) | `[95:92]` | bolos en la última hora |
| `[16:15]` | alarma (1 sin flujo, 2 flujo libre, 3 manipulación) | `[103:96]` | segundos de sesión restantes |
| `[17]` | sesión activa | `[111:104]` | contador de eventos |
| `[25:18]` | ID de la enfermera en sesión | `[135:112]` | evento 0 (el más reciente) |
| `[35:26]` | mL entregados | `[159:136]` | evento 1 |
| `[45:36]` | velocidad (mL/h) | `[183:160]` | evento 2 |
| `[55:46]` | volumen (mL) | `[207:184]` | evento 3 |
| `[63:56]` | bolo (mL) | `[208]` | bomba encendida |
| `[71:64]` | bloqueo (min) | `[209]` | gabinete abierto (con antirrebote) |
| `[75:72]` | bolos máx/hora | `[212:210]` | gabinete, tubo tapado, llave (switch **o** panel) |
| | | `[215:213]` | fallas pedidas por el panel de simulación |

El mismo mapa está en `STATUS_FIELDS` de [fpga_bridge.py](../server/fpga_bridge.py) y en la asignación `probe` de [dispenser_top.v](../rtl/dispenser_top.v); ambos deben coincidir.

## Bitácora de eventos

Cada evento ocupa 24 bits: `{código[7:0], argumento[15:0]}`. La FPGA guarda los 4 últimos y un contador. Si dos eventos ocurren en el mismo ciclo, una cola de banderas pendientes los registra uno por ciclo para no perder ninguno. Con el contador, el servidor detecta los eventos nuevos y arma la bitácora de la página.

| Código | Evento | Argumento |
|---|---|---|
| `01` | FPGA encendida / reiniciada | — |
| `02` | Sesión abierta | ID de la enfermera |
| `05` | Sesión cerrada (manual o por tiempo) | ID de la enfermera |
| `06` | Parámetro cambiado | `{sel, valor}` |
| `07` | Infusión iniciada | velocidad |
| `08` | Infusión en pausa | mL entregados |
| `09` | Infusión terminada | mL entregados |
| `0A` | Bolo concedido | bolos en la hora |
| `0B` | Bolo rechazado | 1 no permitido · 2 bloqueo · 3 máximo por hora |
| `0C` | Alarma | código de alarma |
| `0D` | Alarma atendida | ID de la enfermera |
| `0E` | Inicio rechazado | — |
| `0F` | Bolsa nueva / contadores en cero | ID de la enfermera |
| `10` | Gabinete abierto | 1 con sesión · 0 sin sesión |
| `11` | Falla simulada desde el panel | bits de falla |
| `12` | Orden rechazada | `{op, resultado}` |
