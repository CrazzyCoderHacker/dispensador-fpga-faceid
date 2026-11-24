# Uso de la tarjeta DE10-Lite

Tarjeta Terasic **DE10-Lite**, FPGA Intel **MAX 10 10M50DAF484C7G**, reloj de 50 MHz. No necesita protoboard ni componentes externos: la bomba y la cámara de goteo se simulan dentro de la FPGA.

## Controles

| Control | Función |
|---|---|
| **KEY0** | Reinicio (vuelve a `id`, borra sesión, programa y contadores) |
| **KEY1** | Pausa local de la infusión (cualquiera puede detenerla) |
| **SW9** | Modo demostración: 1 minuto clínico = 1 segundo (bloqueo y ventana de bolos) |
| **SW7** | Simula *llave abierta a mano* → alarma de flujo libre |
| **SW6** | Simula *tubo tapado / bolsa vacía* → alarma sin flujo |
| **SW5** | Simula *gabinete abierto* → alarma de manipulación si no hay sesión |
| **SW1–SW0** | Qué muestra HEX3–HEX0: `00` mL entregados · `01` velocidad · `10` min de bloqueo restantes · `11` ID de la enfermera |
| SW8, SW4–SW2 | Sin uso |

Las fallas de SW7–SW5 también se pueden provocar desde el **panel "Simulador de fallas"** de la página (orden `SIM`). La FPGA usa el OR de ambas fuentes.

> Para la demostración, deja **todos los switches abajo** (y SW9 arriba si quieres los minutos acelerados). Un switch de falla olvidado arriba provoca alarmas que parecen "fantasma".

## Displays de 7 segmentos

```
 HEX5 HEX4   HEX3 HEX2 HEX1 HEX0
 [ estado ]  [   valor o alarma  ]
```

| Display | Significado |
|---|---|
| `id 0000` | Inactivo |
| `ru 0006` | Infundiendo (6 mL entregados) |
| `PA 0000` | En pausa |
| `dn 0003` | Terminado (3 mL) |
| `AL noFL` | Alarma: sin flujo |
| `AL FrEE` | Alarma: flujo libre |
| `AL tAPA` | Alarma: gabinete abierto sin permiso |

## LEDs

| LED | Significado |
|---|---|
| LEDR0 | Sesión de enfermería abierta |
| LEDR1 | Bomba encendida (parpadea: lazo cerrado) |
| LEDR2 | Cae una gota |
| LEDR3 | Bolo concedido (0.8 s) |
| LEDR4 | Orden o bolo rechazado (0.8 s) |
| LEDR5 | Gabinete abierto |
| LEDR8 | Latido (1 Hz): la FPGA está viva |
| LEDR9 | Alarma |

## Salidas opcionales en GPIO (JP1)

No se usan en la demostración, pero quedan listas por si después se conectan una bomba y un zumbador reales:

| Pin | Señal |
|---|---|
| GPIO[4] | PWM de la bomba |
| GPIO[5] | IN1 del puente H (bomba encendida) |
| GPIO[6] | IN2 del puente H (fijo en 0) |
| GPIO[10] | Zumbador |
| GPIO[11] | LED de alarma externo |

## Asignación de pines

Todas las asignaciones están en [quartus/dispensador.qsf](../quartus/dispensador.qsf). Siguen la asignación estándar de la DE10-Lite (System Builder de Terasic) y se comprobaron en la tarjeta: reloj `PIN_P11`, KEY0 `PIN_B8`, KEY1 `PIN_A7`, SW0–SW9, LEDR0–LEDR9 y HEX0–HEX5.
