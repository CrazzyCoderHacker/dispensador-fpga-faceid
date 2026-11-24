# Guion de la demostración

Antes de empezar:

1. Tarjeta programada y servidor + túnel corriendo ([como-correr.md](como-correr.md)).
2. En la tarjeta: **SW9 arriba**, todos los demás switches **abajo**. Presiona **KEY0** → `id 0000`.
3. En el iPhone: caras registradas de la **enfermera (ID 3)** y del **paciente (ID 55)**.

> La sesión de enfermería dura 2 minutos sin actividad. Si LEDR0 se apaga, vuelve a *Entrar con Face ID*.

| # | Caso | Qué hacer | Qué se ve |
|---|---|---|---|
| 1 | **Infusión correcta** | Enfermera: *Entrar con Face ID* → elegir paciente 55 → *Cargar programa* → *Iniciar* | `ru`, LEDR1 y LEDR2 parpadean, suben los mL |
| 2 | **Accesos no autorizados** | *Cerrar sesión* y tocar *Iniciar* o *Cargar programa*. Luego, con sesión, velocidad 0 o 2000 | "Primero entra con Face ID"; "Valor fuera de rango" |
| 3 | **Bolo del paciente** | Paciente: *Pedir bolo con Face ID* dos veces seguidas | 1.º concedido (LEDR3), 2.º negado por bloqueo (LEDR4) |
| 4 | **Bolo de otra persona** | Pedir el bolo con la cara de la enfermera o de otro paciente | "Solo el paciente puede pedir su bolo" / "La cara no corresponde" |
| 5 | **Flujo libre** | Con la infusión corriendo: *Abrir la llave a mano* (o SW7) | `AL FrEE`, LEDR9, bomba apagada en < 1 s |
| 6 | **Bolsa vacía** | Quitar la falla, atender, *Iniciar*, luego *Tapar tubo* (o SW6) | `AL noFL` a los ~5 s |
| 7 | **Gabinete sin permiso** | *Cerrar sesión* → *Abrir el gabinete* (o SW5) | `AL tAPA`, LEDR5 y LEDR9 |
| 8 | **Gabinete con permiso** | Con sesión abierta, *Abrir el gabinete* | Sin alarma (la enfermera puede abrirlo) |
| 9 | **Atender alarma** | Quitar la falla → enfermera *Atender alarma* | `PA`; sin sesión no se puede |
| 10 | **Pausa** | Paciente *Pausar infusión* (sin sesión) o KEY1 | `PA`; reanudar requiere enfermera |
| 11 | **Fin** | Con sesión: velocidad 999, volumen 5, *Iniciar* | `dn 0005` en ~20 s, bomba apagada |
| 12 | **Sesión expira** | No tocar nada 2 min con sesión abierta | LEDR0 se apaga, "Sesión cerrada" |

Reglas para que la demo salga limpia:

- Una alarma **vuelve a dispararse** si la falla sigue activa: primero quita la falla (el botón deja de estar naranja o el switch baja) y después atiende.
- *Atender alarma / bolsa nueva*, con la infusión en pausa y sin alarma, **pone los mL en cero**. Úsalo solo para atender alarmas o al terminar.
- En la **Bitácora** de la página aparece cada evento registrado por la FPGA.
