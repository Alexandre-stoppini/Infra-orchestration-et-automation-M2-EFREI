# VéloCité Data Platform v2

**Plateforme pédagogique. Données inventées, réseau isolé, aucun secret réel.**

VéloCité est un opérateur fictif de mobilité partagée à Bordeaux : vélos et
trottinettes connectés, comptes usagers, trajets, facturation. La version 2 est
la plateforme durcie à l'issue du module Sécurité 1 (détail dans
`SECURITE.md`). C'est l'existant que l'équipe d'exploitation reçoit.

## Ce qu'il faut

Docker Desktop, PowerShell. Rien d'autre pour lancer en local.

## Lancer en local

Depuis ce dossier. Windows (PowerShell) :

```powershell
./scripts/init-secrets.ps1      # une seule fois : génère ./secrets
docker compose up -d
docker compose ps -a
```

macOS et Linux (Terminal) :

```bash
./scripts/init-secrets.sh       # une seule fois : génère ./secrets
docker compose up -d
docker compose ps -a
```

Comptez une à deux minutes. Les services `init-stockage` et `seed` doivent
finir en `Exited (0)` ; tous les autres en `Up (healthy)`.

Vérifier :

```powershell
curl.exe --ssl-no-revoke --cacert secrets/ca.crt https://localhost:8443/api/version
docker compose --profile verif run --rm verif
```

Sous macOS et Linux : `curl --cacert secrets/ca.crt https://localhost:8443/api/version`.

Le portail interne est sur https://localhost:8443 (le navigateur signale un
certificat inconnu : l'autorité est locale, son certificat est
`secrets\ca.crt`).

Arrêter : `docker compose down`. Repartir de zéro : `docker compose down -v`,
puis `docker compose up -d`.

## Les services

| Service | Rôle | Port interne | Image |
|---|---|---|---|
| `nginx` | frontal TLS, seul point d'entrée | 8080, 8443 (publiés sur 127.0.0.1) | `velocite/nginx:2.0.0` |
| `api` | comptes, trajets, statistiques | 8080, métriques 9100 | `velocite/api:2.0.0` |
| `ingest` | télémétrie des véhicules | 8081, métriques 9100 | `velocite/ingest:2.0.0` |
| `loadgen` | générateur d'activité et client témoin | métriques 9100 | `velocite/loadgen:2.0.0` |
| `postgres` | référentiel | 5432 (TLS) | `velocite/postgres:2.0.0` (base `postgres:18.6-alpine`) |
| `redis` | limiteur et cache | 6379 (ACL) | `redis:8.8.3-alpine` |
| `garage` | stockage objet S3 | 3900, admin 3903 | `dxflrs/garage:v2.4.1` |
| `init-stockage`, `seed` | initialisation, une fois | - | `velocite/init:2.0.0` |
| `batch` | bilan quotidien (profil `batch`) | - | `velocite/batch:1.0.0`, à construire |

## La configuration, en un tableau

| Variable | Service | Obligatoire | Rôle |
|---|---|---|---|
| `DATABASE_URL` | api, ingest, batch, seed | oui | connexion PostgreSQL du rôle du service |
| `REDIS_URL` | api | oui | connexion Redis du compte `api` |
| `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | api, batch, seed | oui | stockage objet |
| `JWT_SECRET` | api | oui, 32 caractères min. | signature des tokens |
| `PSEUDO_KEY` | api, batch | oui pour l'export | clé de pseudonymisation |
| `INGEST_DEVICE_KEY` | ingest, loadgen | oui | clé de flotte |
| `TRIPS_CACHE_TTL` | api | **oui à partir de 2.2.0** | durée du cache des statistiques |
| `JWT_TTL_SECONDS` | api | non (900) | durée de vie d'un token |
| `EXPORT_MAX_ROWS` | api | non (5000) | plafond d'une page d'export |
| `ALLOWED_ORIGINS` | api | non (vide) | origines autorisées en CORS |
| `VELOCITE_ENV` | api | non (dev) | nom de l'environnement |
| `BATCH_FAIL_RATE` | batch | non (0) | injecteur de pannes pour l'exercice |
| `PUSHGATEWAY_URL` | batch | non | où `signaler` dépose l'issue du bilan |

Toute variable secrète peut se passer par fichier : `NOM_FILE=/chemin`.

## Codes de sortie

| Code | Sens | Relancer ? |
|---|---|---|
| 0 | succès | - |
| 2 | donnée invalide (job batch) | non : il faut un humain |
| 75 | panne temporaire | oui |
| 78 | configuration absente ou invalide | non : corriger la configuration |

## Le job batch

```powershell
docker compose --profile batch build batch
docker compose --profile batch run --rm batch extract --date 2026-03-12
```

Étapes : `extract`, `check`, `aggregate`, `publish`, `purge`, et `signaler`
qui publie l'issue du bilan pour la supervision. Le détail est en tête de
`services/batch/batch.py`.

## Rappel

Tout ce qui ressemble à une donnée personnelle a été inventé. Les pièces
d'identité de `datasets/kyc/` sont des rectangles de couleur portant la mention
"PIECE FACTICE - SUPPORT DE COURS".
