# VéloCité v2 - ce qui a été durci

Ce document liste ce qui a changé depuis le socle de Sécurité 1, avec pour
chaque point le défaut d'origine, la correction et l'endroit où elle se
trouve. Les contrôles automatiques sont dans `tests/verifier_durcissement.py`
(34 contrôles, lancés par `docker compose --profile verif run --rm verif`).

Ce module ne porte plus sur la sécurité : ce durcissement est le point de
départ. Votre travail est de le **conserver** en industrialisant le
déploiement. Un déploiement automatisé qui réintroduit un secret en clair ou
un port ouvert est une régression. Elle se voit.

## Ce qui a changé

| Défaut du socle de septembre | Correction v2 | Où |
|---|---|---|
| Secrets en clair dans un `.env` versionné | Un fichier par secret, généré, jamais versionné ; lu par `NOM_FILE` | `scripts/init-secrets.ps1`, `services/*/config.py` |
| Secrets par défaut dans le code | Aucune valeur secrète par défaut : le service refuse de démarrer | `services/api/config.py` |
| Mots de passe en MD5 et colonne en clair | argon2id, empreinte seule | `db/postgres/01-schema.sql`, `services/api/auth.py` |
| Tokens sans expiration, `alg: none` accepté | HS256 imposé côté serveur, expiration 15 min | `services/api/auth.py` |
| Aucune limite sur les échecs de connexion | Suspension après cinq échecs en cinq minutes, et 10 tentatives par minute au frontal | `services/api/app.py`, `nginx/nginx.conf` |
| Lecture des trajets de n'importe quel compte | Titulaire, support, admin ou service seulement | route `/users/{id}/trips` |
| Route d'export complète sans authentification | Supprimée ; l'équipe data a une extraction pseudonymisée, plafonnée et comptée | route `/exports/trips` |
| Route de diagnostic qui renvoyait tout l'environnement | Supprimée ; une erreur 500 ne renvoie qu'un identifiant de requête | `services/api/app.py` |
| Numéros de carte et IBAN en clair | Quatre derniers chiffres, jeton de carte, IBAN masqué | `db/postgres/data/billing.csv` |
| Bucket des pièces d'identité en lecture publique | Aucun accès anonyme ; l'API sert la pièce au rôle support, avec une ligne d'audit | `services/init/init.py`, route `/users/{id}/kyc` |
| Un compte superutilisateur partagé par tous les services | Un rôle PostgreSQL par service, au strict nécessaire | `db/postgres/03-roles.sh` |
| PostgreSQL joignable sans TLS | TLS 1.3 obligatoire, certificat vérifié (`verify-full`) | `db/postgres/pg_hba.conf`, `tls-entrypoint.sh` |
| Redis sans mot de passe | ACL : compte `default` désactivé, compte `api` limité à ses clés, commandes dangereuses interdites | `secrets/redis_users.acl` |
| MinIO root partagé ; MinIO communautaire plus maintenu | Garage, une clé par service, droits par bucket, cycle de vie sur les données brutes | `garage/garage.toml`, `services/init/init.py` |
| Tous les ports publiés sur toutes les interfaces | Seul le frontal est publié, sur 127.0.0.1 ; réseau des données isolé (`internal`) | `compose.yaml` |
| Socket Docker monté dans le frontal ; logs servis par HTTP | Supprimés | `compose.yaml`, `nginx/nginx.conf` |
| TLS 1.0 et 1.1 au frontal | TLS 1.2 et 1.3, HSTS, en-têtes de sécurité, version masquée | `nginx/nginx.conf` |
| CORS ouvert à toutes les origines | Liste blanche (`ALLOWED_ORIGINS`), vide par défaut | `services/api/app.py` |
| Images anciennes, dépendances non figées, exécution en root | Base pinnée par digest, `--require-hashes`, utilisateur 10001, pip retiré, système de fichiers en read-only | `services/*/Dockerfile`, `compose.yaml` |
| PostgreSQL et Redis démarrés en root avec cinq capacités | Démarrés sous leur utilisateur (uid 70, uid 999), aucune capacité ajoutée ; `gosu` retiré de l'image PostgreSQL | `db/postgres/Dockerfile`, `compose.yaml` |
| Logs avec mots de passe essayés, emails et téléphones | Champs sensibles masqués à l'écriture ; sortie standard uniquement | `services/*/logx.py` |
| Télémétrie acceptée sans authentification ni contrôle | Clé de flotte, bornes géographiques et plages de valeurs, lot plafonné | `services/ingest/app.py` |

## Matrice d'habilitation

`R` lecture, `W` écriture, `-` aucun droit. Une case vide est une décision.

| Acteur | users | trips | billing | telemetry | agrégats | KYC | raw | curated |
|---|---|---|---|---|---|---|---|---|
| `svc_api` | R (colonnes utiles), W `last_login_at` | R, W | R (colonnes masquées) | - | - | R | - | - |
| `svc_ingest` | - | - | - | W | - | - | - | - |
| `svc_batch` | - | R | - | purge | R, W | - | R, W | R, W |
| `svc_seed` | W `password_hash` | - | - | - | - | W | W | - |

## Ce qui reste ouvert, et pourquoi

- **Vulnérabilités de la base Debian sans correctif publié** (44 HIGH au
  12 octobre 2026, aucune corrigeable). Politique retenue : bloquer sur ce qui
  a un correctif, suivre le reste. Une base distroless les réduirait.
- **Garage tourne en root dans Compose.** Son image ne contient qu'un binaire
  et pas de shell ; les capacités sont retirées et le système de fichiers est
  en lecture seule. Sur Kubernetes, il tourne sans privilège.
- **Le lien nginx vers l'API reste en HTTP sur le réseau interne.** Le
  chiffrement de bout en bout (mTLS entre services) relève d'un maillage de
  services, hors du périmètre.
- **Les certificats locaux sont auto-signés**, valables 90 jours. Sur
  Kubernetes, OpenTofu les régénère à chaque nouvel environnement.
