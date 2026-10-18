# Génère les secrets et les certificats de l'environnement Compose local,
# dans le dossier .\secrets (ignoré par Git). Ne remplace rien s'ils existent.
#
# Usage, depuis le dossier app :   .\scripts\init-secrets.ps1
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
# Piège Windows : si "docker compose up" a été lancé avant ce script (ou après
# un échec de ce script), Docker Desktop crée un DOSSIER vide à la place de
# chaque secret manquant. On les retire, avec le projet qui n'a pas pu démarrer.
if (Test-Path secrets/jwt_secret -PathType Container) {
    Write-Host "Dossiers vides à la place des secrets (compose up lancé sans secrets) : nettoyage."
    docker compose down -v
    Remove-Item -Recurse -Force secrets
}
New-Item -ItemType Directory -Force -Path secrets | Out-Null
docker compose build init-stockage
docker run --rm --user 0 -v "$(Join-Path $PWD secrets):/out" velocite/init:2.0.0 secrets /out
Get-ChildItem secrets | Select-Object Name, Length | Format-Table -AutoSize
