<#
.SYNOPSIS
  Sauvegarde la base PostgreSQL d'un environnement dans un fichier .sql, sur
  votre poste, dans le dossier sauvegardes/ (ignoré par Git).

.DESCRIPTION
  1. pg_dump tourne dans le pod postgres et écrit /tmp/sauvegarde.sql
     (options --clean --if-exists : la restauration remplace les tables
     existantes au lieu de se heurter à elles).
  2. kubectl cp rapatrie ce fichier sur le poste, horodaté.
  3. Le fichier est effacé du pod : son /tmp est un petit volume (64 Mi).
  Le fichier ne passe jamais par un pipe PowerShell : Windows PowerShell 5.1
  y abîmerait les accents. Il contient des données personnelles : il ne va
  jamais dans Git.

.EXAMPLE
  .\scripts\sauvegarder.ps1
  .\scripts\sauvegarder.ps1 -Env prod
  pwsh ./scripts/sauvegarder.ps1          # macOS, Linux
#>
param([ValidateSet("dev", "prod")][string]$Env = "dev")
. "$PSScriptRoot/commun.ps1"

$ns = "velocite-$Env"
$dossier = Join-Path $Racine "sauvegardes"
New-Item -ItemType Directory -Force -Path $dossier | Out-Null
$horodatage = Get-Date -Format "yyyyMMdd-HHmmss"
$fichier = "sauvegardes/velocite-$Env-$horodatage.sql"

# A FAIRE (atelier 10) : trois commandes, chacune par Invoke-Commande, qui
# s'arrête si la commande échoue. Le modèle : scripts/compter-bilan.ps1.
#   1. Dans le pod, pg_dump écrit /tmp/sauvegarde.sql :
#        kubectl -n $ns exec statefulset/postgres '--' sh -c $dump
#      où $dump est la commande lancée dans le pod : utilisateur postgres,
#      base velocite, options --clean --if-exists, -f /tmp/sauvegarde.sql,
#      le mot de passe lu dans le pod :
#        PGPASSWORD=$(cat /run/secrets/postgres_password)
#      Écrivez '--' entre apostrophes : sans elles, PowerShell l'avale.
#   2. kubectl cp "$ns/postgres-0:/tmp/sauvegarde.sql" $fichier, lancé
#      depuis la racine du dépôt (Push-Location $Racine, puis Pop-Location).
#   3. Effacer /tmp/sauvegarde.sql dans le pod (rm -f).
# Puis afficher le nom du fichier et sa taille.

$aFaire = "A FAIRE (atelier 10) : ce script ne sauvegarde encore rien."
Write-Host $aFaire -ForegroundColor Yellow
