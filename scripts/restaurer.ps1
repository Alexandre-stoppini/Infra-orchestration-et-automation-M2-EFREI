<#
.SYNOPSIS
  Restaure la base PostgreSQL d'un environnement depuis un fichier .sql de
  sauvegardes/ (écrit par sauvegarder.ps1).

.DESCRIPTION
  1. kubectl cp envoie le fichier dans le /tmp du pod postgres.
  2. psql le rejoue, en s'arrêtant à la première erreur (ON_ERROR_STOP) :
     les tables sont supprimées puis recréées avec leurs lignes.
  3. Le fichier est effacé du pod.
  Sans -Fichier, la sauvegarde la plus récente de l'environnement est prise.
  La durée affichée est votre RTO mesuré, pour la restauration seule.

.EXAMPLE
  .\scripts\restaurer.ps1
  .\scripts\restaurer.ps1 -Fichier sauvegardes/velocite-dev-20261023.sql
  pwsh ./scripts/restaurer.ps1            # macOS, Linux
#>
param(
    [ValidateSet("dev", "prod")][string]$Env = "dev",
    [string]$Fichier
)
. "$PSScriptRoot/commun.ps1"

$ns = "velocite-$Env"
Push-Location $Racine
try {
    if (-not $Fichier) {
        $dernier = Get-ChildItem -Path "sauvegardes" `
            -Filter "velocite-$Env-*.sql" -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
        if (-not $dernier) {
            throw ("Aucune sauvegarde de $ns dans sauvegardes/ : " +
                   "lancez d'abord scripts/sauvegarder.ps1.")
        }
        $Fichier = "sauvegardes/$($dernier.Name)"
    }
    if (-not (Test-Path $Fichier)) {
        throw "Fichier introuvable : $Fichier"
    }
} finally { Pop-Location }

# A FAIRE (atelier 10) : chronométrez ce qui suit, avec
# [System.Diagnostics.Stopwatch]::StartNew() (le modèle : Invoke-Etape,
# dans scripts/commun.ps1), puis :
#   1. Attendre que la base soit prête :
#        kubectl -n $ns rollout status statefulset/postgres --timeout=300s
#   2. kubectl cp $Fichier "$ns/postgres-0:/tmp/restauration.sql", lancé
#      depuis la racine du dépôt.
#   3. Dans le pod, psql rejoue le fichier : utilisateur postgres, base
#      velocite, -v ON_ERROR_STOP=1 (arrêt à la première erreur),
#      -f /tmp/restauration.sql, le mot de passe comme dans sauvegarder.ps1.
#   4. Effacer /tmp/restauration.sql dans le pod.
# Puis afficher la durée : c'est votre RTO mesuré.
# Ne passez jamais le fichier par un pipe PowerShell (Get-Content ... |) :
# Windows PowerShell 5.1 y abîmerait les accents. Toujours kubectl cp.

$aFaire = "A FAIRE (atelier 10) : ce script ne restaure encore rien."
Write-Host "$aFaire ($Fichier)" -ForegroundColor Yellow
