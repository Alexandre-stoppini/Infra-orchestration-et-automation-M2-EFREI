"""Outils d'initialisation de VéloCité v2. Trois sous-commandes :

  secrets <dossier>   génère tous les secrets et certificats d'un
                      environnement Compose local (un fichier par secret)
  stockage            configure Garage : layout, clés par service, buckets,
                      droits, cycle de vie. Utilise le token d'administration.
  seed                dépose les pièces KYC et le jeu pseudonymisé avec la clé
                      du service seed, puis pose les empreintes des comptes
                      fixes dans PostgreSQL avec le rôle svc_seed.

Chaque sous-commande est idempotente : la relancer ne change rien de plus.
Sur Kubernetes, `secrets` n'est pas utilisée : OpenTofu génère les secrets.
"""

import ipaddress
import json
import os
import secrets as rnd
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from logx import Logger

log = Logger("init")


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
        sys.exit(78)
    return defaut


# ===================================================================== secrets

def cle_garage():
    """Format imposé par Garage : GK + 24 hexadécimaux, secret de 64."""
    return "GK" + rnd.token_hex(12), rnd.token_hex(32)


def certificats(dossier, noms_nginx, noms_postgres):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    def pem_cle(k):
        return k.private_bytes(serialization.Encoding.PEM,
                               serialization.PrivateFormat.PKCS8,
                               serialization.NoEncryption())

    maintenant = datetime.now(timezone.utc)
    ca_cle = ec.generate_private_key(ec.SECP256R1())
    ca_nom = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,
                                           "VeloCite CA locale")])
    ca = (x509.CertificateBuilder()
          .subject_name(ca_nom).issuer_name(ca_nom)
          .public_key(ca_cle.public_key())
          .serial_number(x509.random_serial_number())
          .not_valid_before(maintenant - timedelta(minutes=5))
          .not_valid_after(maintenant + timedelta(days=365))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
          .add_extension(x509.KeyUsage(False, False, False, False, False, True,
                                       True, False, False), True)
          .add_extension(x509.SubjectKeyIdentifier.from_public_key(
              ca_cle.public_key()), False)
          .sign(ca_cle, hashes.SHA256()))

    def serveur(nom, sans):
        cle = ec.generate_private_key(ec.SECP256R1())
        alt = []
        for s in sans:
            try:
                alt.append(x509.IPAddress(ipaddress.ip_address(s)))
            except ValueError:
                alt.append(x509.DNSName(s))
        cert = (x509.CertificateBuilder()
                .subject_name(x509.Name([x509.NameAttribute(
                    NameOID.COMMON_NAME, sans[0])]))
                .issuer_name(ca_nom).public_key(cle.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(maintenant - timedelta(minutes=5))
                .not_valid_after(maintenant + timedelta(days=90))
                .add_extension(x509.SubjectAlternativeName(alt), False)
                .add_extension(x509.ExtendedKeyUsage(
                    [ExtendedKeyUsageOID.SERVER_AUTH]), False)
                # Python 3.13 et OpenSSL 3 en mode strict exigent ces deux
                # identifiants pour relier le certificat à son autorité.
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(
                    cle.public_key()), False)
                .add_extension(x509.AuthorityKeyIdentifier
                               .from_issuer_public_key(ca_cle.public_key()),
                               False)
                .sign(ca_cle, hashes.SHA256()))
        (dossier / (nom + ".crt")).write_bytes(
            cert.public_bytes(serialization.Encoding.PEM))
        (dossier / (nom + ".key")).write_bytes(pem_cle(cle))

    (dossier / "ca.crt").write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    serveur("nginx", noms_nginx)
    serveur("postgres", noms_postgres)


def cmd_secrets(cible):
    dossier = Path(cible)
    dossier.mkdir(parents=True, exist_ok=True)
    if (dossier / "jwt_secret").exists():
        log.event("info", "secrets_deja_presents", dossier=str(dossier))
        print("Les secrets existent déjà dans {} : rien n'est écrasé.".format(
            dossier))
        return

    def ecrire(nom, valeur):
        p = dossier / nom
        p.write_text(valeur + "\n", encoding="utf-8")
        p.chmod(0o644)

    mdp = {n: rnd.token_urlsafe(24) for n in (
        "postgres_password", "pg_svc_api", "pg_svc_ingest", "pg_svc_batch",
        "pg_svc_seed", "redis_api", "redis_sonde", "admin_password",
        "service_password", "datasci_password", "analyst_password",
        "support_password")}
    for nom, v in mdp.items():
        ecrire(nom, v)

    ca = "sslmode=verify-full&sslrootcert=/run/secrets/ca.crt"
    for svc in ("api", "ingest", "batch", "seed"):
        ecrire("database_url_" + svc,
               "postgresql://svc_{0}:{1}@postgres:5432/velocite?{2}".format(
                   svc, mdp["pg_svc_" + svc], ca))
    ecrire("redis_url_api", "redis://api:{}@redis:6379/0".format(
        mdp["redis_api"]))
    ecrire("redis_users.acl", "\n".join([
        "user default off",
        "user api on >{} ~rl:* ~cache:* -@all +@read +@write +@connection "
        "-@dangerous".format(mdp["redis_api"]),
        "user sonde on >{} -@all +ping +@connection".format(
            mdp["redis_sonde"]),
    ]))

    ecrire("jwt_secret", rnd.token_urlsafe(48))
    ecrire("pseudo_key", rnd.token_hex(32))
    ecrire("ingest_device_key", rnd.token_urlsafe(32))
    ecrire("garage_rpc_secret", rnd.token_hex(32))
    ecrire("garage_admin_token", rnd.token_urlsafe(32))
    ecrire("garage_metrics_token", rnd.token_urlsafe(32))
    for svc in ("api", "seed", "batch"):
        ident, secret = cle_garage()
        ecrire("s3_{}_key_id".format(svc), ident)
        ecrire("s3_{}_secret".format(svc), secret)

    certificats(dossier,
                ["nginx", "localhost", "velocite.localhost", "127.0.0.1"],
                ["postgres", "localhost"])
    for nom in ("nginx.key", "postgres.key"):
        (dossier / nom).chmod(0o644)
    log.event("info", "secrets_generes", dossier=str(dossier),
              fichiers=len(list(dossier.iterdir())))
    print("Secrets générés dans {}. Ce dossier ne se versionne jamais.".format(
        dossier))


# ==================================================================== stockage

BUCKETS = {
    # bucket : (règles de cycle de vie, droits par service)
    "velocite-raw": ([{"ID": "brut-13-mois", "Status": "Enabled",
                       "Filter": {"Prefix": "trips/"},
                       "Expiration": {"Days": 395}}],
                     {"seed": "rw", "batch": "rw"}),
    "velocite-curated": ([], {"batch": "rw"}),
    "velocite-kyc": ([], {"seed": "rw", "api": "r"}),
}


class Admin:
    def __init__(self, url, token):
        import requests
        self.url = url.rstrip("/")
        self.s = requests.Session()
        self.s.headers["Authorization"] = "Bearer " + token

    def get(self, op, **params):
        r = self.s.get(self.url + "/v2/" + op, params=params, timeout=10)
        return r

    def post(self, op, corps, **params):
        r = self.s.post(self.url + "/v2/" + op, params=params, json=corps,
                        timeout=10)
        if r.status_code >= 400:
            raise RuntimeError("{} {} : {}".format(op, r.status_code,
                                                   r.text[:200]))
        return r.json() if r.content else {}


def attendre(nom, essai, tentatives=90):
    for i in range(1, tentatives + 1):
        try:
            if essai():
                log.event("info", "pret", cible=nom, tentative=i)
                return
        except Exception:  # noqa: BLE001 - on attend, quelle que soit l'erreur
            pass
        time.sleep(2)
    log.event("error", "jamais_pret", cible=nom)
    sys.exit(75)


def cmd_stockage():
    admin = Admin(lire("GARAGE_ADMIN_URL", defaut="http://garage:3903",
                       obligatoire=False), lire("GARAGE_ADMIN_TOKEN"))
    capacite = int(lire("GARAGE_CAPACITY_BYTES", obligatoire=False,
                        defaut=str(5 * 1024 ** 3)))
    attendre("garage", lambda: admin.get("GetClusterStatus").status_code == 200)

    statut = admin.get("GetClusterStatus").json()
    disposition = admin.get("GetClusterLayout").json()
    if not disposition.get("roles"):
        noeud = statut["nodes"][0]["id"]
        admin.post("UpdateClusterLayout", {"roles": [{
            "id": noeud, "zone": "dc1", "capacity": capacite, "tags": []}]})
        admin.post("ApplyClusterLayout",
                   {"version": statut["layoutVersion"] + 1})
        log.event("info", "layout_applique", noeud=noeud[:16])
    else:
        log.event("info", "layout_deja_en_place",
                  version=statut["layoutVersion"])

    cles = {}
    for svc in ("api", "seed", "batch"):
        ident = lire("S3_{}_KEY_ID".format(svc.upper()))
        secret = lire("S3_{}_SECRET".format(svc.upper()))
        if admin.get("GetKeyInfo", id=ident).status_code == 200:
            log.event("info", "cle_deja_presente", service=svc)
        else:
            admin.post("ImportKey", {"accessKeyId": ident,
                                     "secretAccessKey": secret,
                                     "name": "svc-" + svc})
            log.event("info", "cle_importee", service=svc)
        cles[svc] = ident

    for bucket, (regles, droits) in BUCKETS.items():
        r = admin.get("GetBucketInfo", globalAlias=bucket)
        if r.status_code == 200:
            ident_bucket = r.json()["id"]
        else:
            ident_bucket = admin.post("CreateBucket",
                                      {"globalAlias": bucket})["id"]
            log.event("info", "bucket_cree", bucket=bucket)
        for svc, d in droits.items():
            admin.post("AllowBucketKey", {
                "bucketId": ident_bucket, "accessKeyId": cles[svc],
                "permissions": {"read": "r" in d, "write": "w" in d,
                                "owner": False}})
        admin.post("UpdateBucket", {"lifecycleRules": regles or None},
                   id=ident_bucket)
        log.event("info", "bucket_pret", bucket=bucket,
                  droits=",".join("{}:{}".format(k, v)
                                  for k, v in droits.items()))
    log.event("info", "stockage_termine")


# ======================================================================== seed

COMPTES = {
    "admin@velocite.example": "ADMIN_PASSWORD",
    "service@velocite.example": "SERVICE_PASSWORD",
    "datasci@velocite.example": "DATASCI_PASSWORD",
    "analyst@velocite.example": "ANALYST_PASSWORD",
    "support@velocite.example": "SUPPORT_PASSWORD",
}


def cmd_seed():
    import boto3
    import psycopg
    from argon2 import PasswordHasher
    from argon2.exceptions import VerifyMismatchError, InvalidHashError
    from botocore.config import Config

    s3 = boto3.client(
        "s3", endpoint_url=lire("S3_ENDPOINT", obligatoire=False,
                                defaut="http://garage:3900"),
        aws_access_key_id=lire("S3_ACCESS_KEY"),
        aws_secret_access_key=lire("S3_SECRET_KEY"),
        region_name=lire("S3_REGION", obligatoire=False, defaut="garage"),
        config=Config(signature_version="s3v4",
                      s3={"addressing_style": "path"}))
    attendre("garage-s3", lambda: s3.head_bucket(Bucket="velocite-kyc") or True)

    donnees = Path(lire("DATASETS_DIR", obligatoire=False, defaut="/datasets"))
    deja = {o["Key"] for p in s3.get_paginator("list_objects_v2").paginate(
        Bucket="velocite-kyc") for o in p.get("Contents", [])}
    deposes = 0
    for f in sorted((donnees / "kyc").glob("*.png")):
        if f.name in deja:
            continue
        s3.put_object(Bucket="velocite-kyc", Key=f.name, Body=f.read_bytes(),
                      ContentType="image/png")
        deposes += 1
    log.event("info", "kyc_deposes", nouveaux=deposes, deja_presents=len(deja))

    csv = donnees / "trajets_2026_pseudo.csv"
    s3.put_object(Bucket="velocite-raw", Key="datasets/" + csv.name,
                  Body=csv.read_bytes(), ContentType="text/csv")
    log.event("info", "dataset_depose", objet="datasets/" + csv.name)

    ph = PasswordHasher()
    dsn = lire("DATABASE_URL")
    attendre("postgres", lambda: psycopg.connect(dsn, connect_timeout=3).close()
             or True)
    with psycopg.connect(dsn, autocommit=True) as c, c.cursor() as cur:
        for email, variable in COMPTES.items():
            mdp = lire(variable)
            cur.execute("SELECT password_hash FROM users WHERE email = %s",
                        (email,))
            ligne = cur.fetchone()
            if ligne is None:
                continue
            try:
                if ligne[0] and ph.verify(ligne[0], mdp):
                    continue
            except (VerifyMismatchError, InvalidHashError):
                pass
            cur.execute("UPDATE users SET password_hash = %s WHERE email = %s",
                        (ph.hash(mdp), email))
            log.event("info", "empreinte_posee", compte=email.split("@")[0])
    log.event("info", "seed_termine")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "secrets":
        cmd_secrets(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "stockage":
        cmd_stockage()
    elif len(sys.argv) == 2 and sys.argv[1] == "seed":
        cmd_seed()
    else:
        print(__doc__)
        sys.exit(64)
