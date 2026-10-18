"""Vérifie, sur la plateforme qui tourne, que le durcissement v2 tient.

Chaque contrôle rejoue une faille du socle de Sécurité 1 et attend le refus.
Lancement, depuis le dossier app :

    docker compose --profile verif run --rm verif

Le frontal limite les connexions à 10 par minute et par adresse : attendre
une minute entre deux lancements, sinon les contrôles de connexion tombent
sur cette limite (et c'est elle qui répond 429).

Sortie : une ligne OK ou KO par contrôle, puis le total. Code de sortie 1 au
premier KO, pour pouvoir chaîner ce script dans une CI ou un smoke test.
"""

import base64
import json
import os
import sys
import time

import requests

S = "/run/secrets/"
FRONTAL = os.getenv("FRONTAL_URL", "https://nginx:8443")
API = FRONTAL + "/api"
CA = S + "ca.crt"
resultats = []


def _essai(f):
    try:
        return f()
    except Exception as e:  # noqa: BLE001
        return e


def secret(nom):
    with open(S + nom, encoding="utf-8") as f:
        return f.read().strip()


def controle(nom, attendu, fonction):
    try:
        obtenu = fonction()
        ok = obtenu == attendu if not callable(attendu) else attendu(obtenu)
    except Exception as e:  # noqa: BLE001
        obtenu, ok = "{}: {}".format(type(e).__name__, str(e)[:80]), False
    resultats.append(ok)
    print("{:<3} {:<62} {}".format("OK" if ok else "KO", nom, obtenu))


def login(email, mdp):
    r = requests.post(API + "/login", json={"email": email, "password": mdp},
                      verify=CA, timeout=15)
    return r.json().get("token") if r.status_code == 200 else None


def get(chemin, token=None, **kw):
    h = {"Authorization": "Bearer " + token} if token else {}
    return requests.get(API + chemin, headers=h, verify=CA, timeout=15, **kw)


def b64(d):
    return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()


print("Vérification du durcissement VéloCité v2 -", time.strftime("%Y-%m-%d %H:%M"))
print("-" * 78)

# --- Frontal ---------------------------------------------------------------
controle("HTTP clair redirigé vers HTTPS", 301, lambda: requests.get(
    FRONTAL.replace("https", "http").replace("8443", "8080") + "/api/version",
    allow_redirects=False, timeout=5).status_code)
controle("Certificat vérifié par l'AC interne", 200,
         lambda: requests.get(FRONTAL + "/healthz", verify=CA, timeout=5).status_code)
controle("Version de nginx masquée (en-tête Server)", "nginx",
         lambda: requests.get(FRONTAL + "/", verify=CA, timeout=5).headers.get("Server"))
controle("En-tête HSTS présent", True, lambda: "max-age" in requests.get(
    FRONTAL + "/", verify=CA, timeout=5).headers.get("Strict-Transport-Security", ""))
controle("Route /logs/ supprimée", 404,
         lambda: requests.get(FRONTAL + "/logs/", verify=CA, timeout=5).status_code)
controle("Route /api/debug/config supprimée", 404, lambda: get("/debug/config").status_code)
controle("Route /api/admin/export supprimée", 404, lambda: get("/admin/export").status_code)

# --- Authentification --------------------------------------------------------
def rafale():
    """Six échecs sur un même email : l'API (pas nginx) doit suspendre."""
    r = None
    for _ in range(6):
        r = requests.post(API + "/login", json={
            "email": "cible@velocite.example", "password": "x"},
            verify=CA, timeout=15)
    return r.status_code, r.headers.get("Content-Type", "").split(";")[0]


controle("Sixième échec en 5 min : suspension par l'API", (429, "application/json"),
         rafale)

time.sleep(15)  # laisse le limiteur du frontal se recharger


service = login("service@velocite.example", secret("service_password"))
datasci = login("datasci@velocite.example", secret("datasci_password"))
support = login("support@velocite.example", secret("support_password"))
controle("Connexion des comptes de service", True, lambda: all([service, datasci, support]))
controle("Mauvais mot de passe refusé", 401, lambda: requests.post(
    API + "/login", json={"email": "service@velocite.example", "password": "service"},
    verify=CA, timeout=15).status_code)
controle("Token alg none refusé", 401, lambda: get(
    "/me", b64({"alg": "none", "typ": "JWT"}) + "." +
    b64({"sub": "1", "role": "admin", "iss": "velocite-api",
         "iat": int(time.time()), "exp": int(time.time()) + 600}) + ".").status_code)
controle("Token signé avec une autre clé refusé", 401, lambda: get(
    "/me", service.rsplit(".", 1)[0] + ".c2lnbmF0dXJlLWZhdXNzZQ").status_code)
controle("Token sans le préfixe Bearer refusé", 401, lambda: requests.get(
    API + "/me", headers={"Authorization": service}, verify=CA, timeout=5).status_code)


# --- Habilitations -------------------------------------------------------------
controle("IDOR : service lit la fiche du compte 42", 403, lambda: get("/users/42", service).status_code)
controle("IDOR : datasci lit les trajets du compte 42", 403, lambda: get("/users/42/trips", datasci).status_code)
controle("Support lit la fiche du compte 42 (son besoin)", 200, lambda: get("/users/42", support).status_code)
controle("Datasci exporte (son besoin)", 200, lambda: get("/exports/trips?limit=5", datasci).status_code)
controle("Export plafonné à EXPORT_MAX_ROWS", 5000, lambda: get(
    "/exports/trips?limit=999999", datasci).json()["count"])
controle("Export pseudonymisé : aucun user_id", True, lambda: all(
    "user_id" not in l for l in get("/exports/trips?limit=50", datasci).json()["rows"]))
controle("Service n'exporte pas", 403, lambda: get("/exports/trips", service).status_code)
controle("Pièce KYC : refusée au compte service", 403, lambda: get("/users/42/kyc", service).status_code)
controle("Pièce KYC : servie au support", "image/png", lambda: get(
    "/users/42/kyc", support).headers.get("Content-Type"))
controle("Facturation d'un tiers refusée au support", 403,
         lambda: get("/billing/42", support).status_code)

# --- Ingestion -------------------------------------------------------------------
lot = {"readings": [{"vehicle_id": 1, "lat": 44.84, "lon": -0.58, "battery_pct": 80, "speed_kmh": 12},
                    {"vehicle_id": 1, "lat": 48.85, "lon": 2.35, "battery_pct": 80, "speed_kmh": 12}]}
controle("Ingestion sans clé de flotte refusée", 401, lambda: requests.post(
    FRONTAL + "/ingest/telemetry/batch", json=lot, verify=CA, timeout=5).status_code)
controle("Relevé hors métropole rejeté, l'autre accepté", {"accepted": 1, "rejected": 1},
         lambda: requests.post(FRONTAL + "/ingest/telemetry/batch", json=lot, verify=CA, timeout=5,
                               headers={"X-Device-Key": secret("ingest_device_key")}).json())

# --- Données ---------------------------------------------------------------------
import psycopg  # noqa: E402
import socket  # noqa: E402
import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402


def pg(url, sql):
    with psycopg.connect(url, connect_timeout=5) as c, c.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()


url_api = secret("database_url_api")
controle("PostgreSQL : connexion sans TLS refusée", True, lambda: "no encryption" in str(
    _essai(lambda: pg(url_api.split("?")[0] + "?sslmode=disable", "SELECT 1"))))


controle("PostgreSQL : svc_api ne lit pas les téléphones", "InsufficientPrivilege",
         lambda: type(_essai(lambda: pg(url_api, "SELECT phone FROM users LIMIT 1"))).__name__)
controle("PostgreSQL : svc_ingest ne lit pas les comptes", "InsufficientPrivilege",
         lambda: type(_essai(lambda: pg(secret("database_url_ingest"),
                                        "SELECT id FROM users LIMIT 1"))).__name__)
controle("PostgreSQL : plus de colonne card_pan", "UndefinedColumn",
         lambda: type(_essai(lambda: pg(url_api, "SELECT card_pan FROM billing"))).__name__)
def redis_brut(*commandes):
    """Parle RESP directement : l'image de vérification n'a pas de client Redis."""
    with socket.create_connection(("redis", 6379), timeout=3) as so:
        reponses = []
        for c in commandes:
            morceaux = c.split(" ")
            trame = "*{}\r\n".format(len(morceaux)) + "".join(
                "${}\r\n{}\r\n".format(len(m), m) for m in morceaux)
            so.sendall(trame.encode())
            reponses.append(so.recv(256).decode().strip())
        return reponses[-1]


controle("Redis : accès anonyme refusé", True,
         lambda: redis_brut("PING").startswith("-NOAUTH"))
controle("Redis : FLUSHALL interdit au compte api", True, lambda: redis_brut(
    "AUTH api " + secret("redis_url_api").split(":")[2].split("@")[0],
    "FLUSHALL").startswith("-NOPERM"))


def s3(cle, sec):
    return boto3.client("s3", endpoint_url="http://garage:3900", region_name="garage",
                        aws_access_key_id=cle, aws_secret_access_key=sec,
                        config=Config(s3={"addressing_style": "path"}))


controle("Stockage : lecture anonyme du bucket KYC refusée", 403, lambda: requests.get(
    "http://garage:3900/velocite-kyc/KYC-2026-000042.png", timeout=5).status_code)
controle("Stockage : la clé de l'API ne peut pas écrire", "AccessDenied", lambda: getattr(
    _essai(lambda: s3(secret("s3_api_key_id"), secret("s3_api_secret")).put_object(
        Bucket="velocite-kyc", Key="test.txt", Body=b"x")), "response", {}).get(
    "Error", {}).get("Code"))
controle("Stockage : la clé du batch ne lit pas le KYC", "AccessDenied", lambda: getattr(
    _essai(lambda: s3(secret("s3_batch_key_id"), secret("s3_batch_secret")).get_object(
        Bucket="velocite-kyc", Key="KYC-2026-000042.png")), "response", {}).get(
    "Error", {}).get("Code"))

print("-" * 78)
total, reussis = len(resultats), sum(resultats)
print("{} contrôles, {} OK, {} KO".format(total, reussis, total - reussis))
sys.exit(0 if reussis == total else 1)
