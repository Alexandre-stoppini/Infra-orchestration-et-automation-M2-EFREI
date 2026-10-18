"""Générateur d'activité de VéloCité v2.

Il fabrique le trafic d'une plateforme en exploitation, par le frontal comme
un vrai client :
- télémétrie des véhicules, avec la clé de flotte ;
- création de trajets par le compte service ;
- consultations d'historique ;
- quelques connexions échouées (mauvais mots de passe) ;
- l'usage normal du compte data science : les statistiques par région ;
- une fois par cycle, sa salve d'extraction : des milliers de lignes
  pseudonymisées d'un coup. Elle est autorisée. C'est le motif que l'alerte
  de la journée 4 doit rendre visible.

Il sert aussi de client témoin : chaque appel est compté côté client
(velocite_client_requests_total, port 9100). C'est la disponibilité vue par
un usager, frontal compris. Quand aucun pod de l'API n'est prêt, l'API ne
compte rien ; le client témoin, lui, compte ses erreurs 502 et ses délais
dépassés.

Les mots de passe des comptes arrivent par fichiers de secrets.
"""

import os
import random
import threading
import time

import requests
from prometheus_client import Counter, Histogram, start_http_server

from logx import Logger

log = Logger("loadgen")


def env(cle, defaut=""):
    chemin = os.getenv(cle + "_FILE")
    if chemin:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip()
    return os.getenv(cle) or defaut


def duree(cle, defaut):
    brut = env(cle, defaut).strip()
    unites = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
    for suffixe in ("ms", "s", "m", "h"):
        if brut.endswith(suffixe):
            try:
                return float(brut[:-len(suffixe)]) * unites[suffixe]
            except ValueError:
                return float(defaut[:-1])
    return float(brut)


BASE = env("FRONTAL_URL", "https://nginx:8443")
VERIFIER_TLS = env("FRONTAL_CA_PATH", "") or False
API = BASE + "/api"
INGEST = BASE + "/ingest"
CLE_FLOTTE = env("INGEST_DEVICE_KEY")
COMPTE_SERVICE = env("SERVICE_EMAIL", "service@velocite.example")
MDP_SERVICE = env("SERVICE_PASSWORD")
COMPTE_DATASCI = env("DATASCI_EMAIL", "datasci@velocite.example")
MDP_DATASCI = env("DATASCI_PASSWORD")
INT_TELEM = duree("TELEMETRY_INTERVAL", "2s")
INT_TRAJET = duree("TRIP_INTERVAL", "6s")
INT_LOGIN = duree("LOGIN_INTERVAL", "9s")
INT_EXFIL = duree("EXFIL_INTERVAL", "20m")
LOTS_EXFIL = int(env("EXFIL_BATCHES", "40"))
LIMITE_EXFIL = int(env("EXFIL_LIMIT", "5000"))
NB_VEHICULES = 300
NB_COMPTES = 500
REGIONS = ["bordeaux-centre", "bordeaux-rive-droite", "begles",
           "merignac", "pessac-talence"]

PORT_METRIQUES = int(env("METRICS_PORT", "9100"))

if not VERIFIER_TLS:
    import urllib3
    urllib3.disable_warnings()  # certificat interne auto-signé en local

REQUETES = Counter("velocite_client_requests_total",
                   "Appels du client témoin, par route et par résultat",
                   ["route", "code"])
DUREES = Histogram("velocite_client_request_duration_seconds",
                   "Durée des appels vue par le client témoin", ["route"],
                   buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30))

# Les identifiants dans les chemins sont remplacés : une étiquette de
# métrique ne doit jamais prendre une valeur par usager.
_ROUTES = [
    ("/api/users/", "/api/users/{id}/trips"),
    ("/api/exports/trips", "/api/exports/trips"),
    ("/api/stats/regions", "/api/stats/regions"),
    ("/api/trips", "/api/trips"),
    ("/api/login", "/api/login"),
    ("/api/readyz", "/api/readyz"),
    ("/ingest/telemetry/batch", "/ingest/telemetry/batch"),
]

# Séries d'échec créées à zéro dès le démarrage : une série n'existe qu'à
# son premier événement, et rate() ignore ce premier saut. Sans elles, le
# premier échec de chaque route ne serait jamais compté.
for _prefixe, _nom in _ROUTES:
    for _code in ("erreur", "502", "503", "504"):
        REQUETES.labels(_nom, _code)


def route_de(url):
    chemin = url[len(BASE):].split("?", 1)[0]
    for prefixe, nom in _ROUTES:
        if chemin.startswith(prefixe):
            return nom
    return "autre"


class SessionMesuree(requests.Session):
    """Session qui compte chaque appel, y compris ceux qui n'aboutissent
    pas (code "erreur" : délai dépassé, connexion refusée, TLS)."""

    def request(self, method, url, *args, **kwargs):
        route = route_de(url)
        debut = time.monotonic()
        try:
            r = super().request(method, url, *args, **kwargs)
        except requests.RequestException:
            REQUETES.labels(route, "erreur").inc()
            raise
        finally:
            DUREES.labels(route).observe(time.monotonic() - debut)
        REQUETES.labels(route, str(r.status_code)).inc()
        return r


sess = SessionMesuree()
sess.verify = VERIFIER_TLS


def arrondi(v):
    return round(v, 6)


def connecter(email, mdp):
    r = sess.post(API + "/login", json={"email": email, "password": mdp},
                  timeout=15)
    if r.status_code != 200:
        raise RuntimeError("login {}".format(r.status_code))
    return r.json()["token"]


def appel(methode, url, token, **kw):
    return sess.request(methode, url, timeout=60,
                        headers={"Authorization": "Bearer " + token}, **kw)


def attendre_frontal():
    for i in range(1, 241):
        try:
            if sess.get(API + "/readyz", timeout=5).status_code == 200:
                log.event("info", "frontal_pret", tentative=i)
                return
        except requests.RequestException:
            pass
        time.sleep(3)
    log.event("error", "frontal_jamais_pret")


def boucle_telemetrie():
    while True:
        lot = [{
            "vehicle_id": random.randint(1, NB_VEHICULES),
            "lat": arrondi(random.uniform(44.79, 44.89)),
            "lon": arrondi(random.uniform(-0.64, -0.53)),
            "battery_pct": random.randint(3, 100),
            "speed_kmh": arrondi(random.uniform(0, 27)),
            "firmware": random.choice(["3.0.2", "3.1.0", "3.1.1"]),
        } for _ in range(15)]
        try:
            r = sess.post(INGEST + "/telemetry/batch", json={"readings": lot},
                          headers={"X-Device-Key": CLE_FLOTTE}, timeout=15)
            if r.status_code >= 300:
                log.event("warn", "telemetrie_refusee", code=r.status_code)
        except requests.RequestException as e:
            log.event("warn", "telemetrie_echec", err=type(e).__name__)
        time.sleep(INT_TELEM)


def boucle_trajets():
    token, expire = None, 0
    while True:
        try:
            if token is None or time.time() > expire:
                token, expire = connecter(COMPTE_SERVICE, MDP_SERVICE), \
                    time.time() + 600
            distance = random.randint(400, 9000)
            charge = {
                "user_id": random.randint(6, NB_COMPTES),
                "vehicle_id": random.randint(1, NB_VEHICULES),
                "start_lat": arrondi(random.uniform(44.79, 44.89)),
                "start_lon": arrondi(random.uniform(-0.64, -0.53)),
                "end_lat": arrondi(random.uniform(44.79, 44.89)),
                "end_lon": arrondi(random.uniform(-0.64, -0.53)),
                "distance_m": distance, "duration_s": distance // 4,
                "price_cents": 100 + distance * 35 // 1000,
                "region": random.choice(REGIONS), "payment_status": "paid",
            }
            r = appel("POST", API + "/trips", token, json=charge)
            if r.status_code == 401:
                token = None
            elif r.status_code >= 400:
                log.event("warn", "trajet_refuse", code=r.status_code)
        except (requests.RequestException, RuntimeError) as e:
            log.event("warn", "trajet_echec", err=type(e).__name__)
            token = None
        time.sleep(INT_TRAJET)


def boucle_consultations():
    token, expire = None, 0
    while True:
        try:
            if token is None or time.time() > expire:
                token, expire = connecter(COMPTE_SERVICE, MDP_SERVICE), \
                    time.time() + 600
            cible = random.randint(6, NB_COMPTES)
            appel("GET", "{}/users/{}/trips?limit=20".format(API, cible), token)
            if random.random() < 0.3:
                # Un mauvais mot de passe sur un compte qui n'existe pas.
                sess.post(API + "/login", timeout=15, json={
                    "email": "inconnu{}@velocite.example".format(
                        random.randint(1, 50)),
                    "password": random.choice(["123456", "azerty", "velo"])})
        except (requests.RequestException, RuntimeError) as e:
            log.event("warn", "consultation_echec", err=type(e).__name__)
            token = None
        time.sleep(INT_LOGIN)


def boucle_datasci():
    """Usage ordinaire, puis la salve d'extraction une fois par cycle."""
    prochaine_salve = time.time() + 90
    while True:
        try:
            token = connecter(COMPTE_DATASCI, MDP_DATASCI)
            appel("GET", API + "/stats/regions", token)
            if time.time() >= prochaine_salve:
                debut, total = time.time(), 0
                for i in range(LOTS_EXFIL):
                    r = appel("GET", "{}/exports/trips?limit={}&offset={}".format(
                        API, LIMITE_EXFIL, i * LIMITE_EXFIL), token)
                    if r.status_code != 200:
                        break
                    n = r.json().get("count", 0)
                    total += n
                    if n == 0:
                        break
                    time.sleep(0.2)
                log.event("info", "salve_datasci", lignes=total,
                          duree_s=int(time.time() - debut))
                prochaine_salve = time.time() + INT_EXFIL
        except (requests.RequestException, RuntimeError) as e:
            log.event("warn", "datasci_echec", err=type(e).__name__)
        time.sleep(60)


def main():
    start_http_server(PORT_METRIQUES)
    log.event("info", "demarrage", frontal=BASE, salve_toutes_les_s=INT_EXFIL,
              metriques=PORT_METRIQUES)
    attendre_frontal()
    fils = [threading.Thread(target=f, daemon=True) for f in (
        boucle_telemetrie, boucle_trajets, boucle_consultations,
        boucle_datasci)]
    for f in fils:
        f.start()
    for f in fils:
        f.join()


if __name__ == "__main__":
    main()
