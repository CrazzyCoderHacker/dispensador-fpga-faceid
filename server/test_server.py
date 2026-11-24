"""Prueba de extremo a extremo del servidor SIN iPhone y SIN tarjeta.

Un autenticador de software (llave P-256, igual que un passkey del iPhone)
registra caras y firma los retos; el servidor verifica las firmas con la misma
libreria que usara con el iPhone, y la FPGA se imita con MockBridge.

Uso:  python server/test_server.py
"""

import base64
import hashlib
import json
import os
import struct
import sys
import time
from pathlib import Path

import cbor2
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

os.environ["ADMIN_PIN"] = "123456"
sys.path.insert(0, str(Path(__file__).parent))
import app as srv  # noqa: E402
from fpga_bridge import MockBridge  # noqa: E402

RP_ID, ORIGIN = "localhost", "http://localhost"
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
unb64u = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class SoftAuthenticator:
    """Imita al llavero del iPhone: una llave por persona; firma con UV=1
    (equivale a que Face ID confirmo la cara)."""

    def __init__(self):
        self.creds = {}   # cred_id -> (llave privada, user_handle, contador)

    def create(self, opts, uv=True):
        key = ec.generate_private_key(ec.SECP256R1())
        nums = key.public_key().public_numbers()
        cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: nums.x.to_bytes(32, "big"), -3: nums.y.to_bytes(32, "big")})
        cred_id = os.urandom(16)
        flags = 0x01 | (0x04 if uv else 0) | 0x40
        auth_data = (hashlib.sha256(RP_ID.encode()).digest() + bytes([flags]) + struct.pack(">I", 0)
                     + bytes(16) + struct.pack(">H", len(cred_id)) + cred_id + cose)
        cdj = json.dumps({"type": "webauthn.create", "challenge": opts["challenge"], "origin": ORIGIN}).encode()
        self.creds[cred_id] = [key, unb64u(opts["user"]["id"]), 0]
        att = cbor2.dumps({"fmt": "none", "attStmt": {}, "authData": auth_data})
        return {"id": b64u(cred_id), "rawId": b64u(cred_id), "type": "public-key",
                "response": {"clientDataJSON": b64u(cdj), "attestationObject": b64u(att), "transports": ["internal"]},
                "clientExtensionResults": {}, "authenticatorAttachment": "platform"}

    def get(self, opts, cred_id, uv=True, tamper=False):
        key, handle, cnt = self.creds[cred_id]
        cnt += 1
        self.creds[cred_id][2] = cnt
        flags = 0x01 | (0x04 if uv else 0)
        auth_data = hashlib.sha256(RP_ID.encode()).digest() + bytes([flags]) + struct.pack(">I", cnt)
        cdj = json.dumps({"type": "webauthn.get", "challenge": opts["challenge"], "origin": ORIGIN}).encode()
        sig = key.sign(auth_data + hashlib.sha256(cdj).digest(), ec.ECDSA(hashes.SHA256()))
        if tamper:
            sig = sig[:-1] + bytes([sig[-1] ^ 1])
        return {"id": b64u(cred_id), "rawId": b64u(cred_id), "type": "public-key",
                "response": {"clientDataJSON": b64u(cdj), "authenticatorData": b64u(auth_data),
                             "signature": b64u(sig), "userHandle": b64u(handle)},
                "clientExtensionResults": {}, "authenticatorAttachment": "platform"}


passed = failed = 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok    {msg}")
    else:
        failed += 1
        print(f"  FALLA {msg}")


def main():
    srv.DATA_FILE = Path(__file__).parent / "usuarios_test.json"
    if srv.DATA_FILE.exists():
        srv.DATA_FILE.unlink()
    srv.bridge = MockBridge()
    phone = SoftAuthenticator()
    ids = {}

    def register(client, name, role, uid, pin="123456"):
        o = client.post("/api/register/options", json={"name": name, "role": role, "id": uid, "pin": pin})
        if o.status_code != 200:
            return o.get_json()
        cred = phone.create(o.get_json())
        ids[uid] = unb64u(cred["id"])
        return client.post("/api/register/verify", data=json.dumps(cred), content_type="application/json").get_json()

    def face_id(client, purpose, uid, **kw):
        o = client.post("/api/auth/options", json={"purpose": purpose}).get_json()
        cred = phone.get(o, ids[uid], **kw)
        r = client.post("/api/auth/verify", json=cred)
        return r.get_json()

    nurse = srv.app.test_client()
    patient = srv.app.test_client()
    other = srv.app.test_client()

    print("== Registro de caras")
    r = register(nurse, "Intrusa", "enfermera", 9, pin="000000")
    check("error" in r, "registro con PIN incorrecto rechazado")
    check(register(nurse, "Ana (enfermera)", "enfermera", 3).get("ok"), "enfermera ID 3 registrada")
    check(register(patient, "Luis (paciente)", "paciente", 55).get("ok"), "paciente ID 55 registrado")
    check(register(other, "Familiar", "paciente", 60).get("ok"), "otra persona ID 60 registrada")
    r = register(nurse, "Mal", "enfermera", 70)
    check("error" in r, "enfermera con ID de paciente rechazada")

    print("== Sesion de enfermeria con Face ID")
    r = nurse.post("/api/program", json={"rate_mlh": 360})
    check(r.status_code == 403, "programar sin Face ID no se permite")
    r = face_id(nurse, "login", 3, tamper=True)
    check("error" in r, "firma alterada rechazada")
    r = face_id(nurse, "login", 3, uv=False)
    check("error" in r, "sin verificacion de Face ID (UV=0) rechazado")
    r = face_id(nurse, "login", 3)
    check(r.get("ok"), "Face ID de enfermera abre sesion en la FPGA")
    s = nurse.get("/api/status").get_json()
    check(s["session"] == 1 and s["session_id"] == 3, "la FPGA reporta sesion de ID 3")

    print("== Programacion e inicio")
    r = nurse.post("/api/program", json={"rate_mlh": 360, "vtbi_ml": 10, "bolus_ml": 1,
                                         "lockout_min": 3, "max_per_hour": 2, "patient_id": 55}).get_json()
    check(r.get("ok"), "programa cargado")
    r = nurse.post("/api/program", json={"rate_mlh": 0, "vtbi_ml": 10, "bolus_ml": 1,
                                         "lockout_min": 3, "max_per_hour": 2, "patient_id": 55}).get_json()
    check(not r.get("ok") and "rango" in r["msg"], "velocidad 0 rechazada por la FPGA")
    r = nurse.post("/api/program", json={"rate_mlh": 2000, "vtbi_ml": 10, "bolus_ml": 1,
                                         "lockout_min": 3, "max_per_hour": 2, "patient_id": 55}).get_json()
    check(not r.get("ok") and "rango" in r["msg"], "velocidad 2000 rechazada (no se trunca a 976)")
    check(nurse.get("/api/status").get_json()["rate_mlh"] == 360, "la velocidad sigue en 360")
    check(nurse.post("/api/cmd/start").get_json().get("ok"), "infusion iniciada")
    check(nurse.post("/api/cmd/logout").get_json().get("ok"), "sesion cerrada")
    s = nurse.get("/api/status").get_json()
    check(s["state"] == 1 and s["session"] == 0, "corriendo y sin sesion")
    r = nurse.post("/api/cmd/start")
    check(r.status_code == 403, "sin sesion el navegador ya no puede mandar ordenes")

    print("== Bolos")
    r = face_id(nurse, "bolus", 3)
    check(not r.get("ok"), "la enfermera no puede pedir el bolo del paciente")
    r = face_id(other, "bolus", 60)
    check(not r.get("ok") and "paciente asignado" in r["msg"], "Face ID de otra persona rechazado por la FPGA")
    r = face_id(patient, "bolus", 55)
    check(r.get("ok"), "Face ID del paciente 55 aceptado")
    time.sleep(0.2)
    s = patient.get("/api/status").get_json()
    check(any("Bolo concedido" in e[1] for e in s["events"]), "bitacora: bolo concedido")
    r = face_id(patient, "bolus", 55)
    check(not r.get("ok") and "bloqueo" in r["msg"], "el iPhone ve el segundo bolo como rechazado por bloqueo")
    s = patient.get("/api/status").get_json()
    check(any("bloqueo" in e[1] for e in s["events"]), "segundo bolo rechazado por bloqueo")

    print("== Pausa sin sesion y bitacora")
    check(other.post("/api/cmd/pause").get_json().get("ok"), "cualquiera puede pausar")
    s = other.get("/api/status").get_json()
    check(s["state"] == 2, "FPGA en pausa")

    print("== Panel de demostracion (fallas simuladas)")
    check(other.post("/api/sim", json={"flags": 1}).get_json().get("ok"), "SIM llave abierta aceptada")
    s = other.get("/api/status").get_json()
    check(s["state"] == 3 and s["alarm"] == 2 and s["valve_open"], "alarma de flujo libre")
    other.post("/api/sim", json={"flags": 0})
    s = other.get("/api/status").get_json()
    check(s["sim_flags"] == 0 and any("Simulacion: llave abierta" in e[1] for e in s["events"]),
          "falla retirada y registrada en bitacora")
    print("  Bitacora:")
    for t, e in reversed(s["events"]):
        print(f"    {t}  {e}")

    srv.DATA_FILE.unlink()
    print(f"\ntest_server RESULT: PASS {passed} FAIL {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
