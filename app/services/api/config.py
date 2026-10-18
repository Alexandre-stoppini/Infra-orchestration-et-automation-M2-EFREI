"""Configuration de l'API, lue au démarrage.

Règles v2 :
- aucune valeur secrète par défaut dans le code ;
- un secret se lit dans la variable NOM, ou dans le fichier désigné par
  NOM_FILE (montage d'un Secret Kubernetes ou d'un secret Compose) ;
- une configuration incomplète arrête le service au démarrage, avec un message
  qui nomme la variable manquante, plutôt qu'une panne au premier appel.
"""

import os
import sys


class ConfigInvalide(Exception):
    pass


def lire(nom, defaut=None, obligatoire=False):
    chemin = os.getenv(nom + "_FILE")
    if chemin:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip()
    valeur = os.getenv(nom)
    if valeur:
        return valeur
    if obligatoire:
        raise ConfigInvalide(nom)
    return defaut


def version_tuple(v):
    try:
        return tuple(int(x) for x in v.split("-")[0].split("."))
    except ValueError:
        return (0, 0, 0)


class Config:
    def __init__(self):
        self.version = os.getenv("APP_VERSION", "0.0.0")
        self.release = version_tuple(self.version)
        self.environnement = lire("VELOCITE_ENV", "dev")

        self.database_url = lire("DATABASE_URL", obligatoire=True)
        self.redis_url = lire("REDIS_URL", obligatoire=True)
        self.s3_endpoint = lire("S3_ENDPOINT", obligatoire=True)
        self.s3_public_endpoint = lire("S3_PUBLIC_ENDPOINT", self.s3_endpoint)
        self.s3_region = lire("S3_REGION", "garage")
        self.s3_access_key = lire("S3_ACCESS_KEY", obligatoire=True)
        self.s3_secret_key = lire("S3_SECRET_KEY", obligatoire=True)
        self.bucket_kyc = lire("BUCKET_KYC", "velocite-kyc")

        self.jwt_secret = lire("JWT_SECRET", obligatoire=True)
        if len(self.jwt_secret) < 32:
            raise ConfigInvalide("JWT_SECRET (32 caractères minimum)")
        self.jwt_ttl = int(lire("JWT_TTL_SECONDS", "900"))

        self.allowed_origins = [o.strip() for o in
                                lire("ALLOWED_ORIGINS", "").split(",")
                                if o.strip()]
        self.export_max = int(lire("EXPORT_MAX_ROWS", "5000"))
        self.metrics_port = int(lire("METRICS_PORT", "9100"))

        # Fonction livrée en 2.2.0 : le cache Redis des statistiques.
        # La durée de vie du cache est OBLIGATOIRE à partir de cette version
        # (voir CHANGELOG.md). Absente, le service refuse de démarrer.
        self.cache_ttl = None
        if self.release >= (2, 2, 0):
            self.cache_ttl = int(lire("TRIPS_CACHE_TTL", obligatoire=True))


def charger(log):
    try:
        return Config()
    except ConfigInvalide as e:
        log.event("error", "config_invalide", manquant=str(e))
        sys.exit(78)  # EX_CONFIG : erreur de configuration, inutile de relancer
    except (OSError, ValueError) as e:
        log.event("error", "config_illisible", err=type(e).__name__)
        sys.exit(78)
