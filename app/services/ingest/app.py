"""Service d'ingestion de la télémétrie des véhicules VéloCité v2.

Les boîtiers poussent position, batterie et vitesse. v2 :
- chaque requête porte la clé de flotte (en-tête X-Device-Key), comparée en
  temps constant ;
- chaque relevé est validé (bornes géographiques de la métropole, plages de
  valeurs) ; un relevé invalide est compté et rejeté, le lot continue ;
- un lot est plafonné à 500 relevés ;
- écriture dans PostgreSQL avec le rôle svc_ingest, qui ne peut qu'insérer.
"""

import hmac
import os
import sys
import threading
import time

import psycopg
from flask import Flask, g, jsonify, request
from prometheus_client import Counter, Gauge, Histogram
from werkzeug.middleware.proxy_fix import ProxyFix

from logx import Logger

log = Logger("ingest")
VERSION = os.getenv("APP_VERSION", "0.0.0")


def lire(nom, obligatoire=True):
    chemin = os.getenv(nom + "_FILE")
    if chemin:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip()
    v = os.getenv(nom)
    if not v and obligatoire:
        log.event("error", "config_invalide", manquant=nom)
        sys.exit(78)
    return v


DSN = lire("DATABASE_URL")
CLE_FLOTTE = lire("INGEST_DEVICE_KEY")
LOT_MAX = 500

ACCEPTES = Counter("velocite_telemetry_accepted_total", "Relevés acceptés")
REJETES = Counter("velocite_telemetry_rejected_total", "Relevés rejetés",
                  ["reason"])
REQUETES = Counter("velocite_http_requests_total", "Requêtes HTTP traitées",
                   ["service", "route", "method", "code"])
DUREE = Histogram("velocite_http_request_duration_seconds",
                  "Durée de traitement", ["service", "route"],
                  buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5))
Gauge("velocite_build_info", "Version déployée",
      ["service", "version"]).labels("ingest", VERSION).set(1)

BORNES = {
    "vehicle_id": (int, 1, 100_000),
    "lat": (float, 44.6, 45.1),
    "lon": (float, -0.9, -0.3),
    "battery_pct": (int, 0, 100),
    "speed_kmh": (float, 0, 60),
}

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1)
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024
_local = threading.local()


def conn():
    c = getattr(_local, "c", None)
    if c is None or c.closed or c.broken:
        c = psycopg.connect(DSN, autocommit=True, connect_timeout=5,
                            application_name="velocite-ingest")
        _local.c = c
    return c


def repondre(code, charge):
    r = jsonify(charge)
    r.status_code = code
    return r


@app.before_request
def _avant():
    g.debut = time.perf_counter()


@app.after_request
def _apres(r):
    route = request.url_rule.rule if request.url_rule else "inconnue"
    if route not in ("/healthz", "/readyz"):
        REQUETES.labels("ingest", route, request.method, r.status_code).inc()
        DUREE.labels("ingest", route).observe(time.perf_counter() - g.debut)
    r.headers["X-Content-Type-Options"] = "nosniff"
    r.headers["Cache-Control"] = "no-store"
    return r


@app.errorhandler(Exception)
def _erreur(exc):
    code = getattr(exc, "code", 500)
    if not isinstance(code, int):
        code = 500
    if code == 500:
        log.event("error", "erreur_interne", type=type(exc).__name__)
    return repondre(code, {"error": "erreur" if code == 500 else str(code)})


@app.get("/healthz")
def healthz():
    return repondre(200, {"status": "ok"})


@app.get("/readyz")
def readyz():
    try:
        with conn().cursor() as cur:
            cur.execute("SELECT 1")
        return repondre(200, {"postgres": "ok"})
    except Exception as e:  # noqa: BLE001
        return repondre(503, {"postgres": type(e).__name__})


@app.get("/version")
def version():
    return repondre(200, {"service": "velocite-ingest", "version": VERSION})


def valider(releve):
    propre = {}
    for champ, (typ, mini, maxi) in BORNES.items():
        try:
            v = typ(releve[champ])
        except (KeyError, TypeError, ValueError):
            return None, "champ_" + champ
        if not mini <= v <= maxi:
            return None, "bornes_" + champ
        propre[champ] = v
    propre["firmware"] = str(releve.get("firmware", ""))[:16]
    propre["ts"] = str(releve.get("ts") or time.strftime(
        "%Y-%m-%d %H:%M:%S", time.gmtime()))[:19]
    return propre, None


@app.post("/telemetry/batch")
def telemetry_lot():
    cle = request.headers.get("X-Device-Key", "")
    if not hmac.compare_digest(cle.encode(), CLE_FLOTTE.encode()):
        REJETES.labels("cle_flotte").inc()
        log.event("warn", "cle_flotte_refusee", ip=request.remote_addr)
        return repondre(401, {"error": "cle de flotte invalide"})
    corps = request.get_json(silent=True) or {}
    releves = corps.get("readings")
    if not isinstance(releves, list) or not releves:
        return repondre(400, {"error": "readings attendu (liste non vide)"})
    if len(releves) > LOT_MAX:
        REJETES.labels("lot_trop_grand").inc(len(releves))
        return repondre(413, {"error": "lot limite a {}".format(LOT_MAX)})

    lignes, rejets = [], 0
    for r in releves:
        propre, raison = valider(r if isinstance(r, dict) else {})
        if propre is None:
            REJETES.labels(raison).inc()
            rejets += 1
            continue
        lignes.append(propre)

    if lignes:
        with conn().cursor() as cur:
            cur.executemany(
                "INSERT INTO telemetry (vehicle_id, ts, lat, lon, battery_pct,"
                " speed_kmh, firmware) VALUES (%(vehicle_id)s, %(ts)s, %(lat)s,"
                " %(lon)s, %(battery_pct)s, %(speed_kmh)s, %(firmware)s)",
                lignes)
        ACCEPTES.inc(len(lignes))
    if rejets:
        log.event("warn", "releves_rejetes", nb=rejets, acceptes=len(lignes))
    return repondre(202, {"accepted": len(lignes), "rejected": rejets})


log.event("info", "demarrage", version=VERSION)
