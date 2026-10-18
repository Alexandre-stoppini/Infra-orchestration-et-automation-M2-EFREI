"""API REST de VéloCité v2 : comptes, trajets, facturation, statistiques.

Version durcie, point de départ du module Infrastructure, orchestration et
automatisation. Le détail de ce qui a changé depuis le socle de Sécurité 1
est dans SECURITE.md, l'historique des versions dans CHANGELOG.md.

Routes de santé :
  /healthz  le processus répond (sonde de vie)
  /readyz   PostgreSQL et Redis répondent (sonde de disponibilité)
  /version  version déployée
Les métriques sont sur un port séparé, voir gunicorn.conf.py.
"""

import hashlib
import json
import time
import uuid

import jwt
import redis as redislib
from flask import Flask, g, jsonify, request
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix

import auth
import metriques as m
from config import charger, lire
from db import Store
from logx import Logger
from stockage import Stockage

log = Logger("api")
cfg = charger(log)
PSEUDO_KEY = lire("PSEUDO_KEY", obligatoire=False) or ""

app = Flask(__name__)
# Un seul mandataire de confiance devant l'API : le frontal nginx. Seule la
# dernière adresse de X-Forwarded-For est retenue, le reste est falsifiable.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024

store = Store(cfg.database_url)
cache = redislib.Redis.from_url(cfg.redis_url, socket_timeout=2,
                                socket_connect_timeout=2,
                                decode_responses=True)
stockage = Stockage(cfg.s3_endpoint, cfg.s3_access_key, cfg.s3_secret_key,
                    cfg.s3_region)
m.BUILD.labels("api", cfg.version).set(1)

ROLES_LECTURE_STATS = {"datascientist", "analyst", "admin"}


def repondre(code, charge):
    r = jsonify(charge)
    r.status_code = code
    return r


def refuser(code, raison):
    route = request.url_rule.rule if request.url_rule else "inconnue"
    m.REFUS.labels(route, raison).inc()
    log.event("warn", "acces_refuse", route=route, raison=raison,
              appelant=g.get("uid", "-"), role=g.get("role", "-"),
              ip=request.remote_addr, request_id=g.request_id)
    return repondre(code, {"error": raison, "request_id": g.request_id})


# ------------------------------------------------------------ intergiciels

@app.before_request
def _avant():
    g.debut = time.perf_counter()
    g.request_id = request.headers.get("X-Request-Id") or uuid.uuid4().hex[:16]


@app.after_request
def _apres(r):
    origine = request.headers.get("Origin")
    if origine and origine in cfg.allowed_origins:
        r.headers["Access-Control-Allow-Origin"] = origine
        r.headers["Vary"] = "Origin"
    r.headers["X-Content-Type-Options"] = "nosniff"
    r.headers["Cache-Control"] = "no-store"
    r.headers["X-Request-Id"] = g.get("request_id", "")
    route = request.url_rule.rule if request.url_rule else "inconnue"
    duree = time.perf_counter() - g.get("debut", time.perf_counter())
    if route not in ("/healthz", "/readyz"):
        m.REQUETES.labels("api", route, request.method, r.status_code).inc()
        m.DUREE.labels("api", route).observe(duree)
        log.event("info", "requete", method=request.method, route=route,
                  code=r.status_code, duree_ms=int(duree * 1000),
                  ip=request.remote_addr, request_id=g.request_id)
    return r


@app.errorhandler(Exception)
def _erreur(exc):
    if isinstance(exc, HTTPException):
        return repondre(exc.code, {"error": exc.name.lower(),
                                   "request_id": g.get("request_id", "")})
    route = request.url_rule.rule if request.url_rule else "inconnue"
    m.REQUETES.labels("api", route, request.method, 500).inc()
    log.event("error", "erreur_interne", route=route,
              type=type(exc).__name__, request_id=g.get("request_id", ""))
    return repondre(500, {"error": "erreur interne",
                          "request_id": g.get("request_id", "")})


# ------------------------------------------------------- authentification

def authentifier(*roles):
    """Lit le token Bearer. Retourne None si tout va bien, une réponse sinon.

    Sans argument, tout compte authentifié passe. Avec des rôles, seuls ceux-là.
    """
    entete = request.headers.get("Authorization", "")
    if not entete.startswith("Bearer "):
        return refuser(401, "authentification absente")
    try:
        claims = auth.verifier(cfg.jwt_secret, entete[7:].strip())
    except jwt.ExpiredSignatureError:
        return refuser(401, "token expire")
    except jwt.InvalidTokenError:
        return refuser(401, "token invalide")
    g.uid = int(claims["sub"])
    g.role = claims["role"]
    if roles and g.role not in roles:
        return refuser(403, "role insuffisant")
    return None


def soi_ou(uid, *roles):
    """Accès à une ressource d'un compte : le titulaire, ou un rôle listé."""
    if g.uid == uid or g.role in roles:
        return None
    return refuser(403, "ressource d'un autre compte")


def entier(valeur, defaut, maximum):
    try:
        v = int(valeur)
    except (TypeError, ValueError):
        return defaut
    return max(0, min(v, maximum))


# ------------------------------------------------------------------ santé

@app.get("/healthz")
def healthz():
    return repondre(200, {"status": "ok"})


@app.get("/readyz")
def readyz():
    etat = {"postgres": "ok", "redis": "ok"}
    code = 200
    try:
        store.ping()
    except Exception as e:  # noqa: BLE001 - on rapporte le type, pas le détail
        etat["postgres"] = type(e).__name__
        code = 503
    try:
        cache.ping()
    except Exception as e:  # noqa: BLE001
        etat["redis"] = type(e).__name__
        code = 503
    return repondre(code, etat)


@app.get("/version")
def version():
    return repondre(200, {"service": "velocite-api", "version": cfg.version,
                          "environnement": cfg.environnement})


# ---------------------------------------------------------------- comptes

def trop_d_echecs(email):
    """Cinq échecs en cinq minutes pour un même email : connexion suspendue."""
    cle = "rl:login:" + hashlib.sha256(email.encode()).hexdigest()[:24]
    try:
        return int(cache.get(cle) or 0) >= 5, cle
    except redislib.RedisError:
        log.event("warn", "limiteur_indisponible")
        return False, cle


def compter_echec(cle):
    try:
        p = cache.pipeline()
        p.incr(cle)
        p.expire(cle, 300)
        p.execute()
    except redislib.RedisError:
        pass


@app.post("/login")
def login():
    corps = request.get_json(silent=True) or {}
    email = str(corps.get("email", ""))[:254].strip().lower()
    mot_de_passe = str(corps.get("password", ""))[:256]

    bloque, cle = trop_d_echecs(email)
    if bloque:
        m.CONNEXIONS.labels("bloque").inc()
        log.event("warn", "connexion_suspendue", ip=request.remote_addr,
                  request_id=g.request_id)
        return repondre(429, {"error": "trop de tentatives, réessayez plus tard"})

    compte = store.identifiants(email) if email else None
    if compte is None:
        auth.leurre(mot_de_passe)
        ok = False
    else:
        ok = auth.verifier_mot_de_passe(compte["password_hash"], mot_de_passe)

    if not ok:
        compter_echec(cle)
        m.CONNEXIONS.labels("echec").inc()
        log.event("warn", "connexion_echec", ip=request.remote_addr,
                  request_id=g.request_id)
        return repondre(401, {"error": "identifiants invalides"})

    store.marquer_connexion(compte["id"])
    m.CONNEXIONS.labels("ok").inc()
    log.event("info", "connexion_ok", user_id=compte["id"], role=compte["role"],
              ip=request.remote_addr, request_id=g.request_id)
    token = auth.emettre(cfg.jwt_secret, cfg.jwt_ttl, compte["id"],
                         compte["role"])
    return repondre(200, {"token": token, "expires_in": cfg.jwt_ttl,
                          "user_id": compte["id"], "role": compte["role"]})


@app.get("/me")
def me():
    refus = authentifier()
    if refus:
        return refus
    return repondre(200, {"user": store.user(g.uid)})


@app.get("/users/<int:uid>")
def user(uid):
    refus = authentifier() or soi_ou(uid, "support", "admin")
    if refus:
        return refus
    u = store.user(uid)
    if u is None:
        return repondre(404, {"error": "compte introuvable"})
    return repondre(200, {"user": u})


@app.get("/users/<int:uid>/trips")
def user_trips(uid):
    refus = authentifier() or soi_ou(uid, "support", "admin", "service")
    if refus:
        return refus
    limite = entier(request.args.get("limit"), 50, 200)
    trajets = store.trajets_du_compte(uid, limite)
    if g.uid != uid:
        log.event("info", "lecture_compte_tiers", appelant=g.uid, role=g.role,
                  compte_lu=uid, nb=len(trajets), request_id=g.request_id)
    return repondre(200, {"user_id": uid, "count": len(trajets),
                          "trips": trajets})


@app.get("/users/<int:uid>/kyc")
def user_kyc(uid):
    refus = authentifier("support", "admin")
    if refus:
        return refus
    u = store.user(uid)
    if u is None:
        return repondre(404, {"error": "compte introuvable"})
    contenu, type_mime = stockage.lire(cfg.bucket_kyc, u["kyc_ref"] + ".png")
    log.event("info", "kyc_consulte", appelant=g.uid, role=g.role,
              compte_lu=uid, request_id=g.request_id)
    r = app.response_class(contenu, status=200, mimetype=type_mime)
    r.headers["Content-Disposition"] = "inline"
    return r


# ---------------------------------------------------------------- trajets

@app.get("/trips")
def list_trips():
    refus = authentifier("support", "admin")
    if refus:
        return refus
    limite = entier(request.args.get("limit"), 100, 500)
    decalage = entier(request.args.get("offset"), 0, 10_000_000)
    trajets = store.trajets(limite, decalage)
    return repondre(200, {"count": len(trajets), "trips": trajets})


CHAMPS_TRAJET = {
    "user_id": (int, 1, 10_000_000), "vehicle_id": (int, 1, 10_000_000),
    "start_lat": (float, 44.6, 45.1), "start_lon": (float, -0.9, -0.3),
    "end_lat": (float, 44.6, 45.1), "end_lon": (float, -0.9, -0.3),
    "distance_m": (int, 0, 200_000), "duration_s": (int, 0, 86_400),
    "price_cents": (int, 0, 100_000),
}


@app.post("/trips")
def create_trip():
    refus = authentifier("service")
    if refus:
        return refus
    t = request.get_json(silent=True) or {}
    propre = {}
    for champ, (typ, mini, maxi) in CHAMPS_TRAJET.items():
        try:
            v = typ(t[champ])
        except (KeyError, TypeError, ValueError):
            return repondre(400, {"error": "champ invalide : " + champ})
        if not mini <= v <= maxi:
            return repondre(400, {"error": "hors bornes : " + champ})
        propre[champ] = v
    maintenant = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    propre["started_at"] = str(t.get("started_at") or maintenant)[:19]
    propre["ended_at"] = str(t.get("ended_at") or maintenant)[:19]
    propre["region"] = str(t.get("region") or "")[:40]
    statut = str(t.get("payment_status") or "pending")
    propre["payment_status"] = statut if statut in (
        "pending", "paid", "failed") else "pending"
    nid = store.creer_trajet(propre)
    m.TRAJETS.inc()
    return repondre(201, {"id": nid})


@app.get("/exports/trips")
def export_trips():
    """Extraction pseudonymisée pour l'équipe data. Volume compté et tracé."""
    refus = authentifier("datascientist")
    if refus:
        return refus
    if not PSEUDO_KEY:
        return repondre(503, {"error": "export indisponible"})
    limite = entier(request.args.get("limit"), 1000, cfg.export_max)
    decalage = entier(request.args.get("offset"), 0, 10_000_000)
    lignes = store.export_pseudonymise(limite, decalage, PSEUDO_KEY)
    m.LIGNES_EXPORTEES.labels(g.role).inc(len(lignes))
    log.event("info", "export_lignes", appelant=g.uid, role=g.role,
              nb=len(lignes), offset=decalage, request_id=g.request_id)
    for ligne in lignes:
        for k in ("start_lat", "start_lon", "end_lat", "end_lon"):
            ligne[k] = float(ligne[k])
    return repondre(200, {"count": len(lignes), "rows": lignes})


def avec_cache(cle, calcul):
    """2.2.0 : met en cache Redis le résultat d'un calcul de statistiques."""
    if cfg.cache_ttl is None:
        return calcul()
    try:
        brut = cache.get("cache:" + cle)
        if brut:
            return json.loads(brut)
    except redislib.RedisError:
        return calcul()
    valeur = calcul()
    try:
        cache.set("cache:" + cle, json.dumps(valeur), ex=cfg.cache_ttl)
    except redislib.RedisError:
        pass
    return valeur


@app.get("/stats/regions")
def stats_regions():
    refus = authentifier(*ROLES_LECTURE_STATS)
    if refus:
        return refus
    return repondre(200, {"regions": avec_cache("regions", store.stats_regions)})


if cfg.release >= (2, 1, 0):
    @app.get("/stats/heures")
    def stats_heures():
        """2.1.0 : répartition des trajets par heure de la journée."""
        refus = authentifier(*ROLES_LECTURE_STATS)
        if refus:
            return refus
        return repondre(200, {"heures": avec_cache("heures",
                                                   store.stats_heures)})


# ------------------------------------------------------------ facturation

@app.get("/billing/<int:uid>")
def billing(uid):
    refus = authentifier() or soi_ou(uid, "admin")
    if refus:
        return refus
    factures = store.factures(uid)
    return repondre(200, {"user_id": uid, "count": len(factures),
                          "invoices": factures})


@app.get("/vehicles")
def vehicles():
    refus = authentifier()
    if refus:
        return refus
    v = store.vehicules(entier(request.args.get("limit"), 100, 500))
    return repondre(200, {"count": len(v), "vehicles": v})


@app.get("/")
def racine():
    routes = ["GET /healthz", "GET /readyz", "GET /version", "POST /login",
              "GET /me", "GET /users/{id}", "GET /users/{id}/trips",
              "GET /users/{id}/kyc", "GET /trips", "POST /trips",
              "GET /exports/trips", "GET /stats/regions",
              "GET /billing/{id}", "GET /vehicles"]
    if cfg.release >= (2, 1, 0):
        routes.append("GET /stats/heures")
    return repondre(200, {"service": "velocite-api", "version": cfg.version,
                          "routes": routes})


log.event("info", "demarrage", version=cfg.version, env=cfg.environnement,
          cache_ttl=cfg.cache_ttl if cfg.cache_ttl is not None else "-")
