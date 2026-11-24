"""Puente laptop <-> FPGA.

JtagBridge  : habla con la DE10-Lite por el cable USB-Blaster usando
              quartus_stp (In-System Sources & Probes). No requiere hardware
              adicional: es el mismo cable con el que se programa la tarjeta.
MockBridge  : imita a la FPGA en software para probar la pagina sin tarjeta.

Formato de orden (32 bits) y mapa de estado (224 bits): ver rtl/cmd_ctrl.v y
rtl/dispenser_top.v. Este archivo y el Verilog deben coincidir.
"""

import os
import shutil
import subprocess
import threading
import time

OP_LOGIN, OP_LOGOUT, OP_SET, OP_START, OP_C, OP_BOLUS, OP_SIM = 1, 2, 3, 4, 5, 6, 7

# fallas simuladas (orden SIM, solo demostracion): bits del argumento
SIM_LEAK, SIM_OCCL, SIM_LID = 1, 2, 4

PARAMS = ["rate_mlh", "vtbi_ml", "bolus_ml", "lockout_min", "max_per_hour", "patient_id"]

# (bit menos significativo, ancho) de cada campo del registro probe
STATUS_FIELDS = {
    "ack_seq": (0, 8),
    "result": (8, 4),
    "state": (12, 3),
    "alarm": (15, 2),
    "session": (17, 1),
    "session_id": (18, 8),
    "delivered_ml": (26, 10),
    "rate_mlh": (36, 10),
    "vtbi_ml": (46, 10),
    "bolus_ml": (56, 8),
    "lockout_min": (64, 8),
    "max_per_hour": (72, 4),
    "patient_id": (76, 8),
    "lockout_left": (84, 8),
    "bolus_count": (92, 4),
    "session_left_s": (96, 8),
    "ev_count": (104, 8),
    "ev0": (112, 24),
    "ev1": (136, 24),
    "ev2": (160, 24),
    "ev3": (184, 24),
    "pump_on": (208, 1),
    "lid_open": (209, 1),
    "valve_open": (210, 1),     # llave abierta (switch SW7 o panel)
    "occluded": (211, 1),       # tubo tapado / bolsa vacia (SW6 o panel)
    "lid_sim": (212, 1),        # gabinete abierto (SW5 o panel)
    "sim_flags": (213, 3),      # lo que pidio el panel de demostracion
}

STATES = {0: "Inactivo", 1: "Infundiendo", 2: "En pausa", 3: "ALARMA", 4: "Terminado"}
ALARMS = {0: "", 1: "Sin flujo (bolsa vacia o tubo tapado)",
          2: "Flujo libre (alguien abrio la llave)", 3: "Gabinete abierto sin autorizacion"}
RESULTS = {0: "OK", 1: "Ese ID no es de enfermeria", 2: "No hay sesion de enfermeria",
           3: "Valor fuera de rango", 4: "La cara no corresponde al paciente asignado",
           5: "Orden desconocida"}
DENY_REASONS = {1: "la infusion no esta corriendo o no hay bolos configurados",
                2: "todavia esta en tiempo de bloqueo", 3: "ya llego al maximo de bolos por hora"}
OP_NAMES = {1: "login", 2: "logout", 3: "programar", 4: "iniciar", 5: "pausa/borrar", 6: "bolo",
            7: "simulacion"}


def decode_status(value):
    s = {k: (value >> lsb) & ((1 << w) - 1) for k, (lsb, w) in STATUS_FIELDS.items()}
    s["state_text"] = STATES.get(s["state"], "?")
    s["alarm_text"] = ALARMS.get(s["alarm"], "")
    return s


def describe_event(ev):
    code, arg = ev >> 16, ev & 0xFFFF
    if code == 0x01:
        return "FPGA encendida / reiniciada"
    if code == 0x02:
        return f"Sesion abierta por enfermera ID {arg}"
    if code == 0x05:
        return f"Sesion cerrada (enfermera ID {arg})"
    if code == 0x06:
        sel, val = (arg >> 12) & 0x7, arg & 0x3FF
        return f"Parametro {PARAMS[sel] if sel < 6 else sel} = {val}"
    if code == 0x07:
        return f"Infusion iniciada a {arg} mL/h"
    if code == 0x08:
        return f"Infusion en pausa ({arg} mL entregados)"
    if code == 0x09:
        return f"Infusion terminada ({arg} mL entregados)"
    if code == 0x0A:
        return f"Bolo concedido (#{arg} en la ultima hora)"
    if code == 0x0B:
        return f"Bolo rechazado: {DENY_REASONS.get(arg, arg)}"
    if code == 0x0C:
        return f"ALARMA: {ALARMS.get(arg, arg)}"
    if code == 0x0D:
        return f"Alarma atendida por enfermera ID {arg}"
    if code == 0x0E:
        return "Inicio rechazado (programa incompleto o sin sesion)"
    if code == 0x0F:
        return f"Contadores reiniciados / bolsa nueva (enfermera ID {arg})"
    if code == 0x10:
        return "Gabinete abierto" + (" (con sesion)" if arg else " SIN sesion")
    if code == 0x11:
        if not arg:
            return "Simulacion: todas las fallas retiradas"
        names = [n for b, n in ((SIM_LEAK, "llave abierta"), (SIM_OCCL, "tubo tapado / bolsa vacia"),
                                (SIM_LID, "gabinete abierto")) if arg & b]
        return "Simulacion: " + ", ".join(names)
    if code == 0x12:
        op, res = arg >> 4, arg & 0xF
        return f"Orden '{OP_NAMES.get(op, op)}' rechazada: {RESULTS.get(res, res)}"
    return f"Evento {code:02X} arg {arg:04X}"


class BridgeBase:
    """Logica comun: numeros de secuencia, acuses y reconstruccion de eventos."""

    def __init__(self):
        self.lock = threading.Lock()
        self.seq = None
        self.ev_seen = None
        self.events = []          # (hora, texto)

    # --- a implementar por cada puente
    def _write(self, word):
        raise NotImplementedError

    def _read(self):
        raise NotImplementedError

    def status(self):
        with self.lock:
            s = decode_status(self._read())
        self._collect_events(s)
        return s

    def send(self, op, arg=0, timeout=2.0):
        with self.lock:
            if self.seq is None:
                self.seq = decode_status(self._read())["ack_seq"]
            self.seq = (self.seq + 1) & 0xFF
            word = (self.seq << 24) | ((op & 0xF) << 20) | (arg & 0xFFFFF)
            self._write(word)
            t0 = time.time()
            while time.time() - t0 < timeout:
                s = decode_status(self._read())
                if s["ack_seq"] == self.seq:
                    break
                time.sleep(0.01)
            else:
                raise TimeoutError("La FPGA no respondio a la orden")
        self._collect_events(s)
        return s["result"], RESULTS.get(s["result"], "?")

    def set_param(self, sel, value):
        # el campo de valor tiene 10 bits: fuera de eso se truncaria en la FPGA
        if not 0 <= value <= 0x3FF:
            return 3, RESULTS[3]
        return self.send(OP_SET, ((sel & 0x7) << 17) | value)

    def simulate(self, flags):
        """Panel de demostracion: simula fallas fisicas; la FPGA las detecta."""
        return self.send(OP_SIM, flags & 7)

    def request_bolus(self, patient_id, timeout=0.5):
        """Manda la solicitud de bolo y espera el veredicto de la FPGA.

        La orden se acusa OK si la cara es la del paciente asignado; si el bolo
        se concede o se niega (bloqueo, maximo por hora) lo decide el limitador
        de la FPGA y lo reporta como evento 0x0A / 0x0B."""
        with self.lock:
            before = decode_status(self._read())["ev_count"]
        code, text = self.send(OP_BOLUS, patient_id)
        if code != 0:
            return False, text
        t0 = time.time()
        while time.time() - t0 < timeout:
            with self.lock:
                s = decode_status(self._read())
            new = min((s["ev_count"] - before) & 0xFF, 4)
            for ev in [s["ev0"], s["ev1"], s["ev2"], s["ev3"]][:new]:
                if ev >> 16 in (0x0A, 0x0B):
                    self._collect_events(s)
                    return ev >> 16 == 0x0A, describe_event(ev)
            time.sleep(0.01)
        return False, "La FPGA no confirmo el bolo"

    def _collect_events(self, s):
        cnt = s["ev_count"]
        if self.ev_seen is None:
            self.ev_seen = (cnt - min(cnt, 4)) & 0xFF
        new = (cnt - self.ev_seen) & 0xFF
        if new == 0:
            return
        hist = [s["ev0"], s["ev1"], s["ev2"], s["ev3"]]
        now = time.strftime("%H:%M:%S")
        if new > 4 and 1 <= cnt <= 4 and (hist[cnt - 1] >> 16) == 0x01:
            # la FPGA se reinicio (KEY0): el contador volvio a empezar
            new = cnt
        if new > 4:
            self.events.append((now, f"({new - 4} eventos no leidos a tiempo)"))
            new = 4
        for ev in reversed(hist[:new]):
            if ev:
                self.events.append((now, describe_event(ev)))
        self.ev_seen = cnt
        del self.events[:-200]


class JtagBridge(BridgeBase):
    """Usa quartus_stp en modo interactivo (Tcl) sobre el USB-Blaster."""

    MARK = "@@"

    def __init__(self, quartus_stp=None, instance_index=0):
        super().__init__()
        default = r"C:\altera_lite\25.1std\quartus\bin64\quartus_stp.exe"
        exe = (quartus_stp or os.environ.get("QUARTUS_STP") or shutil.which("quartus_stp")
               or (default if os.path.exists(default) else None))
        if not exe:
            raise RuntimeError("No encuentro quartus_stp. Instala Quartus Prime Lite o define QUARTUS_STP.")
        self.idx = instance_index
        self.p = subprocess.Popen([exe, "-s"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, bufsize=1)
        self._tcl("set hw [lindex [get_hardware_names] 0]")
        self._tcl("set dev [lindex [get_device_names -hardware_name $hw] 0]")
        self._tcl("start_insystem_source_probe -device_name $dev -hardware_name $hw")

    def _tcl(self, cmd):
        self.p.stdin.write(f'puts "{self.MARK}[catch {{{cmd}}} r]|$r{self.MARK}"\n')
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("quartus_stp se cerro")
            if self.MARK in line:
                body = line.split(self.MARK)[1]
                err, _, res = body.partition("|")
                if err.strip() != "0":
                    raise RuntimeError(f"Error de quartus_stp en '{cmd}': {res}")
                return res.strip()

    def _write(self, word):
        self._tcl(f"write_source_data -instance_index {self.idx} -value_in_hex -value {word:08X}")

    def _read(self):
        return int(self._tcl(f"read_probe_data -instance_index {self.idx} -value_in_hex"), 16)

    def close(self):
        try:
            self._tcl("end_insystem_source_probe")
            self.p.stdin.write("exit\n")
            self.p.stdin.flush()
        except Exception:
            pass


class MockBridge(BridgeBase):
    """Imitacion en software de la FPGA (misma logica simplificada) para
    probar la pagina y el Face ID sin la tarjeta conectada."""

    def __init__(self, demo_minutes_are_seconds=True):
        super().__init__()
        self.m = dict(ack_seq=0, result=0, state=0, alarm=0, session=0, session_id=0,
                      delivered_ml=0, rate_mlh=0, vtbi_ml=0, bolus_ml=0, lockout_min=10,
                      max_per_hour=0, patient_id=0, lockout_left=0, bolus_count=0,
                      session_left_s=0, ev_count=0, ev0=0, ev1=0, ev2=0, ev3=0,
                      pump_on=0, lid_open=0, valve_open=0,
                      occluded=0, lid_sim=0, sim_flags=0)
        self.noflow_since = None
        self.minute_s = 1.0 if demo_minutes_are_seconds else 60.0
        self.drops = 0.0
        self.sched = 0.0
        self.boluses = []
        self.last_bolus = -1e9
        self.session_until = 0.0
        self.t = time.time()
        self._event(0x01, 0)

    def _event(self, code, arg):
        m = self.m
        m["ev3"], m["ev2"], m["ev1"] = m["ev2"], m["ev1"], m["ev0"]
        m["ev0"] = (code << 16) | arg
        m["ev_count"] = (m["ev_count"] + 1) & 0xFF

    def _advance(self):
        now = time.time()
        dt, self.t = now - self.t, now
        m = self.m
        if m["session"] and now > self.session_until:
            m["session"] = 0
            self._event(0x05, m["session_id"])
        m["session_left_s"] = max(0, int(self.session_until - now)) if m["session"] else 0
        vtbi_drops = m["vtbi_ml"] * 20
        if m["state"] == 1 and m["rate_mlh"]:
            self.sched = min(vtbi_drops, self.sched + dt * m["rate_mlh"] * 20 / 3600.0)
            self.drops = min(self.sched, self.drops + dt / 0.15)
            m["delivered_ml"] = int(self.drops // 20)
            if self.drops >= vtbi_drops:
                m["state"] = 4
                self._event(0x09, m["delivered_ml"])
        m["pump_on"] = int(m["state"] == 1 and self.drops < self.sched)
        f = m["sim_flags"]
        m["valve_open"], m["occluded"] = int(bool(f & SIM_LEAK)), int(bool(f & SIM_OCCL))
        m["lid_sim"] = m["lid_open"] = int(bool(f & SIM_LID))
        alarm = 0
        if m["lid_open"] and not m["session"] and m["state"] != 3:
            alarm = 3
        elif m["valve_open"] and m["state"] != 3:
            alarm = 2
        elif m["occluded"] and m["state"] == 1:
            self.noflow_since = self.noflow_since or now
            if now - self.noflow_since > 5:
                alarm = 1
        if not m["occluded"]:
            self.noflow_since = None
        if alarm:
            m["state"], m["alarm"], m["pump_on"] = 3, alarm, 0
            self._event(0x0C, alarm)
        left = self.m["lockout_min"] * self.minute_s - (now - self.last_bolus)
        m["lockout_left"] = max(0, int(left / self.minute_s + 0.999))
        self.boluses = [b for b in self.boluses if now - b < 60 * self.minute_s]
        m["bolus_count"] = len(self.boluses)

    def _read(self):
        self._advance()
        v = 0
        for k, (lsb, w) in STATUS_FIELDS.items():
            v |= (self.m[k] & ((1 << w) - 1)) << lsb
        return v

    def _write(self, word):
        self._advance()
        m = self.m
        seq, op, arg = word >> 24, (word >> 20) & 0xF, word & 0xFFFFF
        if seq == m["ack_seq"]:
            return
        m["ack_seq"] = seq
        res, aid = 0, arg & 0xFF
        if op == OP_LOGIN:
            if 1 <= aid <= 49:
                if not m["session"] or m["session_id"] != aid:
                    m["session_id"] = aid
                    self._event(0x02, aid)
                m["session"] = 1
                self.session_until = time.time() + 120
            else:
                res = 1
        elif op == OP_LOGOUT:
            if m["session"]:
                m["session"] = 0
                self._event(0x05, m["session_id"])
            else:
                res = 2
        elif op == OP_SET:
            sel, val = (arg >> 17) & 7, arg & 0x3FF
            ok = {0: 1 <= val <= 999, 1: 1 <= val <= 999, 2: val <= 50, 3: val <= 240,
                  4: val <= 8, 5: val == 0 or 50 <= val <= 99}.get(sel, False)
            if not m["session"]:
                res = 2
            elif not ok:
                res = 3
            else:
                m[PARAMS[sel]] = val
                self._event(0x06, (sel << 12) | val)
                self.session_until = time.time() + 120
        elif op == OP_START:
            if not m["session"]:
                res = 2
            elif m["state"] in (0, 2) and m["rate_mlh"] and m["vtbi_ml"]:
                m["state"] = 1
                self.sched = self.drops
                self._event(0x07, m["rate_mlh"])
            else:
                self._event(0x0E, 0)
        elif op == OP_C:
            if m["state"] == 1:
                m["state"] = 2
                self._event(0x08, m["delivered_ml"])
            elif m["session"] and m["state"] == 3:
                m["state"], m["alarm"] = 2, 0
                self._event(0x0D, m["session_id"])
            elif m["session"]:
                m["state"], self.drops, self.sched, m["delivered_ml"] = 0, 0.0, 0.0, 0
                self._event(0x0F, m["session_id"])
        elif op == OP_BOLUS:
            if m["patient_id"] and aid != m["patient_id"]:
                res = 4
            else:
                now = time.time()
                if m["state"] != 1 or not m["bolus_ml"] or not m["max_per_hour"]:
                    self._event(0x0B, 1)
                elif now - self.last_bolus < m["lockout_min"] * self.minute_s:
                    self._event(0x0B, 2)
                elif len(self.boluses) >= m["max_per_hour"]:
                    self._event(0x0B, 3)
                else:
                    self.boluses.append(now)
                    self.last_bolus = now
                    self.sched = min(m["vtbi_ml"] * 20, self.sched + m["bolus_ml"] * 20)
                    self._event(0x0A, len(self.boluses))
        else:
            res = 5
        if op == OP_SIM:
            res = 0
            if (arg & 7) != m["sim_flags"]:
                m["sim_flags"] = arg & 7
                self._event(0x11, arg & 7)
        m["result"] = res
        if res:
            self._event(0x12, (op << 4) | res)
