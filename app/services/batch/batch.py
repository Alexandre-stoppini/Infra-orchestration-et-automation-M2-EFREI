"""Job batch VéloCité : le bilan quotidien des trajets.

Un seul programme, une sous-commande par étape du pipeline :

  extract   --date AAAA-MM-JJ   trajets du jour -> velocite-raw (CSV pseudonymisé)
  check     --date AAAA-MM-JJ   contrôle qualité du CSV extrait
  aggregate --date AAAA-MM-JJ   agrégats région x heure -> velocite-curated
                                et table daily_region_stats
  publish   --date AAAA-MM-JJ   pose le marqueur _SUCCESS du jour
  purge     --days N            supprime la télémétrie plus vieille que N jours
  signaler  --statut STATUT     publie l'issue du bilan pour la supervision
                                (Succeeded, Failed, Error), vers la
                                Pushgateway si PUSHGATEWAY_URL est défini

Codes de sortie, lus par l'orchestrateur :
  0   succès
  2   donnée invalide : relancer ne servira à rien, il faut un humain
  75  panne temporaire (base ou stockage injoignable) : relancer a un sens
  78  configuration absente

Chaque étape est idempotente : relancée pour la même date, elle réécrit le
même objet et remplace les mêmes lignes. Rien ne se duplique.

BATCH_FAIL_RATE (0 à 1) injecte une panne temporaire aléatoire. Il sert à
l'exercice sur les reprises ; il vaut 0 par défaut.
"""

import argparse
import csv
import hashlib
import hmac
import io
import json
import os
import random
import sys
import time
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from logx import Logger

log = Logger("batch")

EX_OK, EX_DONNEE, EX_TEMPORAIRE, EX_CONFIG = 0, 2, 75, 78
BUCKET_BRUT = "velocite-raw"
BUCKET_CURE = "velocite-curated"


class PanneTemporaire(Exception):
    pass


class DonneeInvalide(Exception):
    pass


def lire(nom, obligatoire=True, defaut=None):
    chemin = os.getenv(nom + "_FILE")
    if chemin:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip()
    v = os.getenv(nom)
    if v:
        return v
    if obligatoire:
        log.event("error", "config_invalide", manquant=nom)
        sys.exit(EX_CONFIG)
    return defaut


def peut_echouer(etape):
    taux = float(os.getenv("BATCH_FAIL_RATE", "0") or 0)
    if taux and random.random() < taux:
        raise PanneTemporaire("panne injectée pendant {}".format(etape))


def s3():
    import boto3
    from botocore.config import Config
    return boto3.client(
        "s3", endpoint_url=lire("S3_ENDPOINT"),
        aws_access_key_id=lire("S3_ACCESS_KEY"),
        aws_secret_access_key=lire("S3_SECRET_KEY"),
        region_name=lire("S3_REGION", obligatoire=False, defaut="garage"),
        config=Config(signature_version="s3v4",
                      s3={"addressing_style": "path"},
                      retries={"max_attempts": 2}, connect_timeout=5))


def base():
    import psycopg
    try:
        return psycopg.connect(lire("DATABASE_URL"), connect_timeout=5,
                               application_name="velocite-batch")
    except psycopg.OperationalError as e:
        raise PanneTemporaire("postgres : " + type(e).__name__) from e


def cle_brute(jour):
    return "trips/date={}/trips.csv".format(jour)


# -------------------------------------------------------------------- étapes

def extract(jour):
    peut_echouer("extract")
    cle_pseudo = lire("PSEUDO_KEY").encode()
    debut = datetime.combine(jour, datetime.min.time())
    with base() as c, c.cursor() as cur:
        cur.execute("SELECT user_id, started_at, start_lat, start_lon,"
                    " end_lat, end_lon, distance_m, duration_s, price_cents,"
                    " region FROM trips WHERE started_at >= %s"
                    " AND started_at < %s ORDER BY id",
                    (debut, debut + timedelta(days=1)))
        lignes = cur.fetchall()
    tampon = io.StringIO()
    w = csv.writer(tampon, lineterminator="\n")
    w.writerow(["pseudo", "heure", "start_lat", "start_lon", "end_lat",
                "end_lon", "distance_m", "duration_s", "price_cents",
                "region"])
    for (uid, debut_t, slat, slon, elat, elon, dist, duree, prix,
         region) in lignes:
        w.writerow([hmac.new(cle_pseudo, str(uid).encode(),
                             hashlib.sha256).hexdigest()[:16],
                    debut_t.hour, round(slat, 3), round(slon, 3),
                    round(elat, 3), round(elon, 3), dist, duree, prix,
                    region or ""])
    corps = tampon.getvalue().encode()
    try:
        s3().put_object(Bucket=BUCKET_BRUT, Key=cle_brute(jour), Body=corps,
                        ContentType="text/csv")
    except Exception as e:  # noqa: BLE001
        raise PanneTemporaire("stockage : " + type(e).__name__) from e
    log.event("info", "extract_ok", date=jour, lignes=len(lignes),
              octets=len(corps), objet=BUCKET_BRUT + "/" + cle_brute(jour))


def lire_brut(jour):
    try:
        obj = s3().get_object(Bucket=BUCKET_BRUT, Key=cle_brute(jour))
    except Exception as e:  # noqa: BLE001
        code = getattr(e, "response", {}).get("Error", {}).get("Code", "")
        if code in ("NoSuchKey", "404"):
            raise DonneeInvalide("extraction absente pour {}".format(jour))
        raise PanneTemporaire("stockage : " + type(e).__name__) from e
    return list(csv.DictReader(io.StringIO(obj["Body"].read().decode())))


def check(jour, autoriser_vide):
    peut_echouer("check")
    lignes = lire_brut(jour)
    anomalies = defaultdict(int)
    for l in lignes:
        for k in ("start_lat", "start_lon", "end_lat", "end_lon"):
            if l[k] == "":
                anomalies["coordonnee_vide"] += 1
        for k in ("distance_m", "duration_s", "price_cents"):
            if l[k] == "" or int(l[k]) < 0:
                anomalies["valeur_negative_ou_vide_" + k] += 1
        if not l["region"]:
            anomalies["region_vide"] += 1
    rapport = {"date": str(jour), "lignes": len(lignes),
               "anomalies": dict(anomalies),
               "verifie_le": datetime.now(timezone.utc).isoformat()}
    s3().put_object(Bucket=BUCKET_BRUT,
                    Key="trips/date={}/_qualite.json".format(jour),
                    Body=json.dumps(rapport, indent=2).encode(),
                    ContentType="application/json")
    if not lignes and not autoriser_vide:
        raise DonneeInvalide("aucun trajet le {}".format(jour))
    if anomalies:
        raise DonneeInvalide("anomalies : " + ", ".join(
            "{}={}".format(k, v) for k, v in sorted(anomalies.items())))
    log.event("info", "check_ok", date=jour, lignes=len(lignes))


def aggregate(jour):
    peut_echouer("aggregate")
    lignes = lire_brut(jour)
    agg = defaultdict(lambda: [0, 0, 0])
    for l in lignes:
        a = agg[(l["region"], int(l["heure"]))]
        a[0] += 1
        a[1] += int(l["distance_m"])
        a[2] += int(l["price_cents"])
    tampon = io.StringIO()
    w = csv.writer(tampon, lineterminator="\n")
    w.writerow(["jour", "region", "heure", "nb_trajets", "distance_m",
                "ca_cents"])
    for (region, heure), (n, dist, ca) in sorted(agg.items()):
        w.writerow([jour, region, heure, n, dist, ca])
    s3().put_object(Bucket=BUCKET_CURE,
                    Key="stats/date={}/region_heure.csv".format(jour),
                    Body=tampon.getvalue().encode(), ContentType="text/csv")
    # Idempotence côté base : une transaction remplace les lignes du jour.
    with base() as c:
        with c.transaction(), c.cursor() as cur:
            cur.execute("DELETE FROM daily_region_stats WHERE jour = %s",
                        (jour,))
            cur.executemany(
                "INSERT INTO daily_region_stats (jour, region, heure,"
                " nb_trajets, distance_m, ca_cents)"
                " VALUES (%s, %s, %s, %s, %s, %s)",
                [(jour, r, h, n, d, ca)
                 for (r, h), (n, d, ca) in sorted(agg.items())])
    log.event("info", "aggregate_ok", date=jour, groupes=len(agg),
              trajets=sum(v[0] for v in agg.values()))


def publish(jour):
    peut_echouer("publish")
    marqueur = {"date": str(jour),
                "workflow": os.getenv("WORKFLOW_NAME", "manuel"),
                "publie_le": datetime.now(timezone.utc).isoformat()}
    s3().put_object(Bucket=BUCKET_CURE,
                    Key="stats/date={}/_SUCCESS".format(jour),
                    Body=json.dumps(marqueur).encode(),
                    ContentType="application/json")
    log.event("info", "publish_ok", date=jour)


def purge(jours):
    peut_echouer("purge")
    with base() as c, c.cursor() as cur:
        cur.execute("DELETE FROM telemetry WHERE ts < now() - %s::interval",
                    ("{} days".format(jours),))
        n = cur.rowcount
        c.commit()
    log.event("info", "purge_ok", jours=jours, lignes_supprimees=n)


def signaler(statut):
    """Un job batch ne vit pas assez longtemps pour être interrogé par
    Prometheus : il dépose son résultat dans la Pushgateway, qui le garde.

    Deux groupes distincts. Le premier est réécrit à chaque exécution
    (dernier statut, heure de fin). Le second ne l'est qu'en cas de succès :
    un échec ne doit pas effacer l'heure du dernier succès, c'est elle qui
    déclenche l'alerte de retard.
    """
    url = lire("PUSHGATEWAY_URL", obligatoire=False)
    # Le namespace est fourni par Kubernetes (downward API) : il permet de
    # rapprocher ces métriques de celles des services du même environnement.
    # Sans VELOCITE_ENV, on déduit l'environnement du namespace.
    namespace = os.getenv("POD_NAMESPACE", "")
    env = lire("VELOCITE_ENV", obligatoire=False,
               defaut=namespace.replace("velocite-", "", 1) or "local")
    namespace = namespace or "velocite-" + env
    succes = statut == "Succeeded"
    maintenant = int(time.time())
    log.event("info" if succes else "error", "bilan_termine", statut=statut,
              env=env)
    if not url:
        log.event("warn", "signalement_ignore", raison="PUSHGATEWAY_URL absent")
        return
    groupes = {"execution": [
        "# TYPE velocite_bilan_dernier_statut gauge",
        "velocite_bilan_dernier_statut {}".format(1 if succes else 0),
        "# TYPE velocite_bilan_derniere_execution_timestamp_seconds gauge",
        "velocite_bilan_derniere_execution_timestamp_seconds {}".format(
            maintenant)]}
    if succes:
        groupes["succes"] = [
            "# TYPE velocite_bilan_dernier_succes_timestamp_seconds gauge",
            "velocite_bilan_dernier_succes_timestamp_seconds {}".format(
                maintenant)]
    from urllib import request
    for groupe, lignes in groupes.items():
        cible = "{}/metrics/job/velocite_bilan/env/{}/namespace/{}/groupe/{}"\
            .format(url.rstrip("/"), env, namespace, groupe)
        corps = ("\n".join(lignes) + "\n").encode()
        try:
            request.urlopen(request.Request(cible, data=corps, method="PUT"),
                            timeout=10)
        except OSError as e:
            # La supervision ne doit pas faire échouer le bilan : on le dit
            # dans les logs, l'alerte de retard prendra le relais.
            log.event("warn", "signalement_echec", groupe=groupe,
                      err=type(e).__name__)


# ----------------------------------------------------------------- lanceur

def main():
    p = argparse.ArgumentParser(description="Bilan quotidien VéloCité")
    p.add_argument("etape", choices=["extract", "check", "aggregate",
                                     "publish", "purge", "signaler"])
    p.add_argument("--date", help="AAAA-MM-JJ, par défaut la veille (UTC)")
    p.add_argument("--days", type=int, default=90)
    p.add_argument("--allow-empty", action="store_true")
    p.add_argument("--statut", default="Succeeded",
                   help="issue du workflow, pour signaler")
    a = p.parse_args()
    if a.etape == "signaler":
        signaler(a.statut)
        return EX_OK
    try:
        jour = (date.fromisoformat(a.date) if a.date else
                datetime.now(timezone.utc).date() - timedelta(days=1))
    except ValueError:
        log.event("error", "date_invalide", valeur=a.date)
        return EX_DONNEE
    t0 = time.time()
    try:
        if a.etape == "extract":
            extract(jour)
        elif a.etape == "check":
            check(jour, a.allow_empty)
        elif a.etape == "aggregate":
            aggregate(jour)
        elif a.etape == "publish":
            publish(jour)
        else:
            purge(a.days)
    except PanneTemporaire as e:
        log.event("error", "panne_temporaire", etape=a.etape, err=str(e))
        return EX_TEMPORAIRE
    except DonneeInvalide as e:
        log.event("error", "donnee_invalide", etape=a.etape, err=str(e))
        return EX_DONNEE
    log.event("info", "etape_terminee", etape=a.etape,
              duree_s=round(time.time() - t0, 2))
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
