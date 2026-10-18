#!/usr/bin/env bash
# Équivalent Linux / macOS de init-secrets.ps1.
set -euo pipefail
cd "$(dirname "$0")/.."
# Si "docker compose up" a été lancé sans secrets, Docker Desktop peut créer un
# dossier vide à la place de chaque secret : on nettoie avant de générer.
if [ -d secrets/jwt_secret ]; then
  echo "Dossiers vides à la place des secrets : nettoyage."
  docker compose down -v
  rm -r secrets
fi
mkdir -p secrets && chmod 700 secrets
docker compose build init-stockage
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/secrets:/out" velocite/init:2.0.0 secrets /out
ls -l secrets
