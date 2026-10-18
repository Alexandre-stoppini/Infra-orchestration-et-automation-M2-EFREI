#!/bin/sh
# Copie le certificat et la clé TLS avec les droits que PostgreSQL exige (clé
# en 0600, propriétaire = l'utilisateur qui lance le serveur), puis passe la
# main au point d'entrée officiel.
#
# L'image démarre sous l'uid 70 (postgres), en Compose comme sur
# Kubernetes : la copie lui appartient déjà. Le cas root reste traité pour
# qui lancerait l'image avec --user 0.
set -eu
SRC="${TLS_DIR:-/run/secrets}"
DST=/var/run/postgresql/tls
mkdir -p "$DST"
cp "$SRC/postgres.crt" "$DST/server.crt"
cp "$SRC/postgres.key" "$DST/server.key"
chmod 0600 "$DST/server.key"
if [ "$(id -u)" = "0" ]; then
  chown -R postgres:postgres "$DST"
fi
exec docker-entrypoint.sh "$@" \
  -c ssl=on \
  -c ssl_cert_file="$DST/server.crt" \
  -c ssl_key_file="$DST/server.key" \
  -c ssl_min_protocol_version=TLSv1.3 \
  -c hba_file=/etc/velocite/pg_hba.conf \
  -c password_encryption=scram-sha-256 \
  -c log_connections=on \
  -c log_line_prefix='%m [%p] %q%u@%d '
