<#
.SYNOPSIS
  Construit les images VéloCité et les charge dans les noeuds kind.

.DESCRIPTION
  Les images velocite/* n'existent dans aucun registre : elles sont
  construites sur le poste, puis copiées dans le containerd de chaque noeud
  par "kind load". Les manifestes les référencent avec
  imagePullPolicy: IfNotPresent, pour que Kubernetes ne les cherche pas en
  ligne. Les images publiques (PostgreSQL de base, Redis, Garage, outils),
  elles, sont tirées par les noeuds depuis leurs registres.

.EXAMPLE
  .\scripts\charger-images.ps1
#>
param([string]$Cluster = "velocite")
. "$PSScriptRoot/commun.ps1"

$app = "$Racine/app"
$images = @(
    @{ Nom = "velocite/postgres:2.0.0"; Contexte = "$app/db/postgres"; Fichier = $null; Version = "2.0.0" },
    @{ Nom = "velocite/init:2.0.0"; Contexte = $app; Fichier = "$app/services/init/Dockerfile"; Version = "2.0.0" },
    @{ Nom = "velocite/api:2.0.0"; Contexte = "$app/services/api"; Fichier = $null; Version = "2.0.0" },
    @{ Nom = "velocite/api:2.1.0"; Contexte = "$app/services/api"; Fichier = $null; Version = "2.1.0" },
    @{ Nom = "velocite/api:2.2.0"; Contexte = "$app/services/api"; Fichier = $null; Version = "2.2.0" },
    @{ Nom = "velocite/ingest:2.0.0"; Contexte = "$app/services/ingest"; Fichier = $null; Version = "2.0.0" },
    @{ Nom = "velocite/nginx:2.0.0"; Contexte = "$app/nginx"; Fichier = $null; Version = "2.0.0" },
    @{ Nom = "velocite/loadgen:2.0.0"; Contexte = "$app/services/loadgen"; Fichier = $null; Version = "2.0.0" },
    @{ Nom = "velocite/batch:1.0.0"; Contexte = "$app/services/batch"; Fichier = $null; Version = "1.0.0" }
)

foreach ($i in $images) {
    $options = @("build", "-q", "--build-arg", "APP_VERSION=$($i.Version)", "-t", $i.Nom)
    if ($i.Fichier) { $options += @("-f", $i.Fichier) }
    Write-Host "    construction de $($i.Nom)"
    Invoke-Commande docker @options $i.Contexte | Out-Null
}

$noms = $images | ForEach-Object { $_.Nom }
Write-Host "    chargement dans kind-$Cluster (une copie par noeud)"
Invoke-Commande kind load docker-image --name $Cluster @noms
