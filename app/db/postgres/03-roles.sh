#!/bin/sh
# ---------------------------------------------------------------------------
# VéloCité v2 - un rôle PostgreSQL par service, au moindre privilège.
#
# Les mots de passe sont lus dans des fichiers de secrets, jamais écrits ici.
# Chaque droit accordé correspond à un usage du code ; une case non accordée
# est une décision (voir SECURITE.md, "Matrice d'habilitation").
# ---------------------------------------------------------------------------
set -eu

secret() { cat "${SECRETS_DIR:-/run/secrets}/$1"; }

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v pw_api="$(secret pg_svc_api)" \
  -v pw_ingest="$(secret pg_svc_ingest)" \
  -v pw_batch="$(secret pg_svc_batch)" \
  -v pw_seed="$(secret pg_svc_seed)" <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;

CREATE ROLE svc_api    LOGIN PASSWORD :'pw_api'    CONNECTION LIMIT 40;
CREATE ROLE svc_ingest LOGIN PASSWORD :'pw_ingest' CONNECTION LIMIT 40;
CREATE ROLE svc_batch  LOGIN PASSWORD :'pw_batch'  CONNECTION LIMIT 5;
CREATE ROLE svc_seed   LOGIN PASSWORD :'pw_seed'   CONNECTION LIMIT 2;
GRANT USAGE ON SCHEMA public TO svc_api, svc_ingest, svc_batch, svc_seed;

-- API : lit ce qu'elle sert, crée des trajets, horodate les connexions.
GRANT SELECT (id, email, full_name, city, region, role, password_hash,
              kyc_ref, created_at, trips_count) ON users TO svc_api;
GRANT UPDATE (last_login_at) ON users TO svc_api;
GRANT SELECT ON vehicles, trips, v_trips_par_region TO svc_api;
GRANT INSERT ON trips TO svc_api;
GRANT USAGE ON SEQUENCE trips_id_seq TO svc_api;
GRANT SELECT (user_id, invoice_ref, period, amount_cents, trips_billed,
              card_brand, card_last4, card_expiry, iban_masked, paid_at)
      ON billing TO svc_api;
GRANT EXECUTE ON FUNCTION hmac(text, text, text) TO svc_api;

-- Ingestion : insère de la télémétrie, ne lit rien.
GRANT INSERT ON telemetry TO svc_ingest;
GRANT USAGE ON SEQUENCE telemetry_id_seq TO svc_ingest;

-- Batch : lit les trajets, remplace ses agrégats, purge la télémétrie.
GRANT SELECT ON trips TO svc_batch;
GRANT SELECT, INSERT, DELETE ON daily_region_stats TO svc_batch;
GRANT SELECT (ts), DELETE ON telemetry TO svc_batch;

-- Seed : pose les empreintes des comptes fixes, rien d'autre.
GRANT SELECT (email, password_hash), UPDATE (password_hash) ON users TO svc_seed;
SQL
