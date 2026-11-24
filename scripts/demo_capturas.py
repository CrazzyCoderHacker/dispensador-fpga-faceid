"""Sesion de demostracion / fotos guiada desde la laptop.

Corre el servidor real en el puerto 5000 (la pagina y el tunel siguen
funcionando) y abre un control local en 127.0.0.1:5001 para llevar la FPGA a
cada caso de prueba y tomar la captura de la pagina con Edge en modo headless.

Las ordenes se mandan directo por JTAG (sin Face ID), por eso el control solo
escucha en 127.0.0.1: no es accesible desde el tunel ni desde la red.

Uso (con la DE10-Lite programada):
    python scripts/demo_capturas.py
    curl http://127.0.0.1:5001/step/inactivo      # y luego programa, infusion,
                                                  # bolos, rechazos, llave, tapado,
                                                  # gabinete, atender, pausa, fin
Las capturas quedan en capturas/NN_<caso>.png
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))
import app as srv  # noqa: E402
from fpga_bridge import (OP_C, OP_LOGIN, OP_LOGOUT, OP_START, SIM_LEAK,  # noqa: E402
                         SIM_LID, SIM_OCCL, JtagBridge)
from flask import Flask, jsonify  # noqa: E402

OUT = ROOT / "capturas"
OUT.mkdir(exist_ok=True)
EDGE = os.environ.get("EDGE", r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
NURSE_ID, PATIENT_ID = 3, 55

if os.environ.get("ADMIN_PIN"):
    srv.ADMIN_PIN = os.environ["ADMIN_PIN"]
b = srv.bridge = JtagBridge()
print(f"PIN de administrador: {srv.ADMIN_PIN}")
threading.Thread(target=lambda: srv.app.run(host="0.0.0.0", port=5000, threaded=True,
                                            use_reloader=False), daemon=True).start()


def wait_state(st, t=15):
    t0 = time.time()
    while time.time() - t0 < t:
        if b.status()["state"] == st:
            return True
        time.sleep(0.05)
    return False


def nurse():
    b.send(OP_LOGIN, NURSE_ID)


def to_idle():
    """FPGA limpia: sin fallas, sin alarma y contadores en cero."""
    b.simulate(0)
    time.sleep(0.1)
    nurse()
    for _ in range(3):
        s = b.status()
        if s["state"] == 0 and s["delivered_ml"] == 0:
            break
        b.send(OP_C)
        time.sleep(0.05)


def program(rate=360, vtbi=999):
    nurse()
    for sel, v in enumerate([rate, vtbi, 1, 5, 2, PATIENT_ID]):
        b.set_param(sel, v)


def running(rate=999, vtbi=999, secs=6):
    if b.status()["state"] != 1:
        to_idle()
        program(rate, vtbi)
        b.send(OP_START)
        time.sleep(secs)


def capture(name):
    time.sleep(1.0)
    n = len(list(OUT.glob("[0-9][0-9]_*.png"))) + 1
    path = OUT / f"{n:02d}_{name}.png"
    subprocess.run([EDGE, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--screenshot={path}", "--force-device-scale-factor=1",
                    "--window-size=480,1500", "--virtual-time-budget=4000",
                    "http://localhost:5000/"], capture_output=True, timeout=60)
    return str(path)


# ------------------------------------------------------------------ casos
def st_inactivo():
    to_idle()
    b.send(OP_LOGOUT)
    b.events.clear()


def st_programa():
    to_idle()
    program()


def st_infusion():
    to_idle()
    program(rate=999)
    b.send(OP_START)
    time.sleep(10)


def st_bolos():
    running()
    return [b.request_bolus(PATIENT_ID), b.request_bolus(PATIENT_ID)]


def st_rechazos():
    nurse()
    r = [b.set_param(0, 0), b.request_bolus(60)]
    b.send(OP_LOGOUT)
    return r


def st_llave():
    running()
    b.simulate(SIM_LEAK)
    wait_state(3)


def st_tapado():
    to_idle()
    running(secs=3)
    b.simulate(SIM_OCCL)
    wait_state(3)


def st_gabinete():
    to_idle()
    running(secs=3)
    b.send(OP_LOGOUT)
    time.sleep(0.2)
    b.simulate(SIM_LID)
    wait_state(3)


def st_atender():
    b.simulate(0)
    time.sleep(0.2)
    nurse()
    b.send(OP_C)


def st_pausa():
    running(secs=4)
    b.send(OP_LOGOUT)
    b.send(OP_C)


def st_fin():
    to_idle()
    program(rate=999, vtbi=3)
    b.send(OP_START)
    wait_state(4, 30)
    b.send(OP_LOGOUT)


STEPS = {k[3:]: v for k, v in dict(globals()).items() if k.startswith("st_")}
ctl = Flask("control")


@ctl.get("/step/<name>")
def step(name):
    if name not in STEPS:
        return jsonify(error=f"caso desconocido; usa uno de {sorted(STEPS)}"), 404
    extra = STEPS[name]()
    s = b.status()
    return jsonify(state=s["state_text"], alarm=s["alarm_text"], ml=s["delivered_ml"],
                   session=s["session"], pump=s["pump_on"], extra=extra,
                   shot=capture(name), events=[e[1] for e in b.events[-6:]])


if __name__ == "__main__":
    print("Control de la demostracion en http://127.0.0.1:5001/step/<caso>")
    print("Casos:", ", ".join(STEPS))
    ctl.run(host="127.0.0.1", port=5001)
