<#
.SYNOPSIS
  Monte VéloCité de zéro sur le poste. Rejouable : un second passage ne
  change rien.

.DESCRIPTION
  Fourni : la structure, le chronométrage, les deux premières étapes.
  A FAIRE au fil de la semaine, chaque fois qu'une étape marche à la main
  (docs/DEPLOIEMENT.md) : l'ajouter ici. Atelier 9 : le script complet,
  avec le contrôle d'idempotence (-Controle).

.EXAMPLE
  $env:TF_VAR_phrase_etat = Read-Host "Phrase du state"
  .\scripts\up.ps1 -Env dev
#>
param(
    [ValidateSet("dev", "prod")][string]$Env = "dev",
    [switch]$Leger,
    [switch]$SansImages,
    [switch]$Controle
)
. "$PSScriptRoot/commun.ps1"

Test-Prerequis -Outils docker, kind, tofu, kubectl
Test-PhraseEtat
$ns = "velocite-$Env"
[string[]]$varsCluster = @()
if ($Leger) { $varsCluster = @("-var=nb_workers=0") }

Invoke-Etape "Cluster kind (infra/00-cluster)" {
    Invoke-Commande tofu "-chdir=$Racine/infra/00-cluster" init -input=false
    Invoke-Commande tofu "-chdir=$Racine/infra/00-cluster" apply -input=false -auto-approve @varsCluster
    Invoke-Commande kubectl config use-context kind-velocite
}

if (-not $SansImages) {
    Invoke-Etape "Images VéloCité, construites et chargées dans kind" {
        & "$PSScriptRoot/charger-images.ps1"
    }
}

# A FAIRE : les outils du cluster (infra/10-outils), avec -var=leger=true
#           si -Leger.
# A FAIRE : l'environnement $Env (infra/20-env) : workspace, puis apply avec
#           le bon fichier de variables.
# A FAIRE : les applications (deploy/overlays/$Env) ; attendre que chaque
#           service soit prêt et que le Job d'initialisation soit terminé.
# A FAIRE : le bilan quotidien (workflows/).
# A FAIRE : les tests de fumée (scripts/smoke.ps1).
# A FAIRE : si -Controle, prouver que rien ne reste à appliquer :
#           "tofu plan -detailed-exitcode" sur chaque couche (code 0 = rien
#           à faire) et "kubectl diff -k" sur l'overlay (code 0 = aucun écart).

Show-Releve
