<#
.SYNOPSIS
  La grosse panne (atelier 10) : la base de dev et son disque sont détruits,
  comme après la perte du serveur qui les portait.

.DESCRIPTION
  1. Le StatefulSet postgres est supprimé, puis le script attend que le pod
     postgres-0 ait disparu.
  2. Le disque de la base, la PVC donnees-postgres-0, est supprimé : toutes
     les données qu'il portait sont perdues.
  3. Le script affiche ce qui reste : rien.
  Il ne recrée rien. Recréer une base vide, puis la restaurer, c'est à vous.
  Il demande une confirmation, sauf avec -Force.

.EXAMPLE
  .\scripts\panne.ps1
  pwsh ./scripts/panne.ps1          # macOS, Linux
#>
param(
    [ValidateSet("dev")][string]$Env = "dev",
    [switch]$Force
)
. "$PSScriptRoot/commun.ps1"

$ns = "velocite-$Env"
Invoke-Silencieux kubectl get --raw /readyz
if ($LASTEXITCODE -ne 0) { throw "Le cluster ne répond pas : Docker Desktop est-il démarré ?" }
if (-not $Force) {
    Write-Host "La base de $ns et son disque vont être détruits." -ForegroundColor Yellow
    Write-Host "Votre sauvegarde est-elle dans sauvegardes/ ?" -ForegroundColor Yellow
    $reponse = Read-Host "Tapez oui pour continuer"
    if ($reponse -ne "oui") { Write-Host "Rien n'a été détruit."; return }
}

Write-Host "==> La base s'arrête" -ForegroundColor Cyan
Invoke-Commande kubectl -n $ns delete statefulset postgres --ignore-not-found
$fin = (Get-Date).AddSeconds(120)
do {
    Invoke-Silencieux kubectl -n $ns get pod postgres-0
    if ($LASTEXITCODE -ne 0) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $fin)
if ($LASTEXITCODE -eq 0) { throw "Le pod postgres-0 ne s'arrête pas : kubectl -n $ns get pods" }

Write-Host "==> Le disque de la base est détruit" -ForegroundColor Cyan
Invoke-Commande kubectl -n $ns delete pvc donnees-postgres-0 --ignore-not-found --timeout=120s

Write-Host ""
Write-Host "Ce qui reste de la base de $ns :" -ForegroundColor Cyan
foreach ($objet in @("statefulset/postgres", "pod/postgres-0", "pvc/donnees-postgres-0")) {
    Invoke-Silencieux kubectl -n $ns get $objet
    $etat = if ($LASTEXITCODE -eq 0) { "encore là" } else { "détruit" }
    Write-Host ("  {0,-24} {1}" -f $objet, $etat)
}
Write-Host ""
Write-Host "La base et ses données sont perdues. À vous : recréez une base vide," -ForegroundColor Yellow
Write-Host "puis restaurez votre sauvegarde (Fiche_Atelier10_J5, étapes 5 et 6)." -ForegroundColor Yellow
