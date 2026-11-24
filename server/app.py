"""Servidor del dispensador: Face ID del iPhone (passkeys / WebAuthn) -> FPGA.

El iPhone abre esta pagina en Safari. Cada accion sensible pide Face ID: el
iPhone firma un reto con una llave que nunca sale del telefono y este servidor
verifica la firma. Solo entonces la orden se manda a la FPGA por JTAG, y la
FPGA vuelve a validar roles, sesion, rangos y limites.

Uso:
    python server/app.py            # con la DE10-Lite conectada (quartus_stp)
    python server/app.py --mock     # sin tarjeta: FPGA simulada en software
"""

import argparse
import json
import os
import secrets
import sys
import time
from pathlib import Path

from flask import Flask, jsonify, render_template, request, session
from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (
    AuthenticatorAttachment,
    AuthenticatorSelectionCriteria,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

sys.path.insert(0, str(Path(__file__).parent))
from fpga_bridge import OP_C, OP_LOGIN, OP_LOGOUT, OP_START, JtagBridge, MockBridge  # noqa: E402

DATA_FILE = Path(__file__).parent / "usuarios.json"

app = Flask(__name__)
app.secret_key = secrets.token_bytes(32)
bridge = None
ADMIN_PIN = os.environ.get("ADMIN_PIN") or f"{secrets.randbelow(10**6):06d}"


# ------------------------------------------------------------------ usuarios
def load_users():
    if DATA_FILE.exists():
        return json.loads(DATA_FILE.read_text(encoding="utf-8"))
    return {"users": []}


def save_users(db):
    DATA_FILE.write_text(json.dumps(db, indent=2, ensure_ascii=False), encoding="utf-8")


def rp_info():
    """El RP ID de WebAuthn es el dominio con el que se abrio la pagina."""
    host = request.headers.get("X-Forwarded-Host") or request.host
    hostname = host.split(":")[0]
    scheme = request.headers.get("X-Forwarded-Proto") or request.scheme
    return hostname, f"{scheme}://{host}"


# ------------------------------------------------------------------ paginas
@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/status")
def api_status():
    s = bridge.status()
    db = load_users()
    s["users"] = [{"name": u["name"], "role": u["role"], "id": u["id"]}
                  for u in db["users"] if u["rp_id"] == rp_info()[0]]
    s["events"] = bridge.events[-25:][::-1]
    s["me"] = session.get("user")
    return jsonify(s)


# ------------------------------------------------------------------ registro
@app.post("/api/register/options")
def register_options():
    body = request.get_json()
    if body.get("pin") != ADMIN_PIN:
        return jsonify(error="PIN de administrador incorrecto"), 403
    role = body.get("role")
    try:
        uid = int(body.get("id"))
    except (TypeError, ValueError):
        return jsonify(error="ID invalido"), 400
    if role == "enfermera" and not 1 <= uid <= 49:
        return jsonify(error="Las enfermeras usan IDs 1 a 49"), 400
    if role == "paciente" and not 50 <= uid <= 99:
        return jsonify(error="Los pacientes usan IDs 50 a 99"), 400
    name = (body.get("name") or "").strip()[:40] or f"{role} {uid}"
    rp_id, _ = rp_info()
    opts = generate_registration_options(
        rp_id=rp_id,
        rp_name="Dispensador FPGA",
        user_id=f"{role}-{uid}".encode(),
        user_name=name,
        user_display_name=f"{name} ({role} {uid})",
        authenticator_selection=AuthenticatorSelectionCriteria(
            authenticator_attachment=AuthenticatorAttachment.PLATFORM,
            resident_key=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
    )
    session["reg"] = {"challenge": bytes_to_base64url(opts.challenge), "role": role, "id": uid, "name": name}
    return app.response_class(options_to_json(opts), mimetype="application/json")


@app.post("/api/register/verify")
def register_verify():
    reg = session.pop("reg", None)
    if not reg:
        return jsonify(error="Registro expirado"), 400
    rp_id, origin = rp_info()
    try:
        v = verify_registration_response(
            credential=request.get_data(as_text=True),
            expected_challenge=base64url_to_bytes(reg["challenge"]),
            expected_rp_id=rp_id,
            expected_origin=origin,
            require_user_verification=True,
        )
    except Exception as e:  # firma o datos invalidos
        return jsonify(error=f"Registro rechazado: {e}"), 400
    db = load_users()
    db["users"] = [u for u in db["users"]
                   if not (u["rp_id"] == rp_id and u["role"] == reg["role"] and u["id"] == reg["id"])]
    db["users"].append({
        "name": reg["name"], "role": reg["role"], "id": reg["id"], "rp_id": rp_id,
        "cred_id": bytes_to_base64url(v.credential_id),
        "public_key": bytes_to_base64url(v.credential_public_key),
        "sign_count": v.sign_count,
    })
    save_users(db)
    return jsonify(ok=True, msg=f"{reg['name']} registrado con Face ID")


# ------------------------------------------------------------------ Face ID
@app.post("/api/auth/options")
def auth_options():
    purpose = request.get_json().get("purpose")      # "login" | "bolus"
    rp_id, _ = rp_info()
    role = "enfermera" if purpose == "login" else "paciente"
    if not any(u["rp_id"] == rp_id and u["role"] == role for u in load_users()["users"]):
        return jsonify(error=f"Todavia no hay ninguna {role} registrada en esta direccion. "
                             "Registra la cara primero (seccion 'Registrar una cara' abajo)."), 400
    opts = generate_authentication_options(
        rp_id=rp_id, user_verification=UserVerificationRequirement.REQUIRED)
    session["auth"] = {"challenge": bytes_to_base64url(opts.challenge), "purpose": purpose}
    return app.response_class(options_to_json(opts), mimetype="application/json")


@app.post("/api/auth/verify")
def auth_verify():
    auth = session.pop("auth", None)
    if not auth:
        return jsonify(error="Autenticacion expirada"), 400
    rp_id, origin = rp_info()
    cred = request.get_json()
    db = load_users()
    user = next((u for u in db["users"] if u["cred_id"] == cred.get("id") and u["rp_id"] == rp_id), None)
    if not user:
        return jsonify(error="Esa cara/passkey no esta registrada en el dispensador"), 403
    try:
        v = verify_authentication_response(
            credential=json.dumps(cred),
            expected_challenge=base64url_to_bytes(auth["challenge"]),
            expected_rp_id=rp_id,
            expected_origin=origin,
            credential_public_key=base64url_to_bytes(user["public_key"]),
            credential_current_sign_count=user["sign_count"],
            require_user_verification=True,
        )
    except Exception as e:
        return jsonify(error=f"Face ID rechazado: {e}"), 403
    user["sign_count"] = v.new_sign_count
    save_users(db)

    if auth["purpose"] == "login":
        code, text = bridge.send(OP_LOGIN, user["id"])
        if code == 0:
            session["user"] = {"name": user["name"], "role": user["role"], "id": user["id"]}
        return jsonify(ok=code == 0, msg=f"{user['name']}: {text}")
    if auth["purpose"] == "bolus":
        if user["role"] != "paciente":
            return jsonify(ok=False, msg="Solo el paciente puede pedir su bolo")
        granted, text = bridge.request_bolus(user["id"])
        return jsonify(ok=granted, msg=f"Solicitud de bolo de {user['name']}: {text}")
    return jsonify(error="Proposito desconocido"), 400


# ------------------------------------------------------------------ enfermeria
def nurse_required():
    u = session.get("user")
    return u if u and u["role"] == "enfermera" else None


@app.post("/api/program")
def api_program():
    if not nurse_required():
        return jsonify(ok=False, msg="Primero entra con Face ID de enfermera"), 403
    body = request.get_json()
    msgs = []
    for sel, key in enumerate(["rate_mlh", "vtbi_ml", "bolus_ml", "lockout_min", "max_per_hour", "patient_id"]):
        try:
            val = int(body.get(key, 0))
        except (TypeError, ValueError):
            return jsonify(ok=False, msg=f"{key}: valor invalido")
        code, text = bridge.set_param(sel, val)
        if code != 0:
            msgs.append(f"{key} = {val}: {text}")
    return jsonify(ok=not msgs, msg="; ".join(msgs) or "Programa cargado en la FPGA")


@app.post("/api/sim")
def api_sim():
    """Panel de demostracion: simula fallas fisicas (no da ningun permiso).
    La FPGA las detecta como si vinieran de sensores y dispara la alarma."""
    flags = int(request.get_json().get("flags", 0)) & 7
    code, text = bridge.simulate(flags)
    return jsonify(ok=code == 0, msg="Simulacion enviada a la FPGA" if code == 0 else text)


@app.post("/api/cmd/<name>")
def api_cmd(name):
    if name == "pause":          # detener siempre se permite
        code, text = bridge.send(OP_C)
        return jsonify(ok=code == 0, msg=text)
    if not nurse_required():
        return jsonify(ok=False, msg="Primero entra con Face ID de enfermera"), 403
    op = {"start": OP_START, "clear": OP_C, "logout": OP_LOGOUT}.get(name)
    if op is None:
        return jsonify(ok=False, msg="Orden desconocida"), 400
    code, text = bridge.send(op)
    if name == "logout":
        session.pop("user", None)
    return jsonify(ok=code == 0, msg=text)


# ------------------------------------------------------------------ main
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mock", action="store_true", help="FPGA simulada (sin tarjeta)")
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT", 5000)))
    ap.add_argument("--quartus-stp", default=None, help="ruta a quartus_stp.exe")
    args = ap.parse_args()

    try:
        bridge = MockBridge() if args.mock else JtagBridge(args.quartus_stp)
    except RuntimeError as e:
        sys.exit(f"No pude hablar con la DE10-Lite: {e}\n"
                 "Revisa que este conectada por USB y programada con quartus/output_files/dispensador.sof,\n"
                 "o usa --mock para probar sin tarjeta.")
    print("=" * 60)
    print(f" Dispensador FPGA  |  modo: {'SIMULADO' if args.mock else 'DE10-Lite por JTAG'}")
    print(f" PIN de administrador para registrar caras: {ADMIN_PIN}")
    print(f" Abre http://localhost:{args.port} (o la URL https del tunel en el iPhone)")
    print("=" * 60)
    app.run(host="0.0.0.0", port=args.port, threaded=True)
