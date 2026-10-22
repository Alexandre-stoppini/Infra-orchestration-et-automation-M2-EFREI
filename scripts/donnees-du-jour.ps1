<#
.SYNOPSIS
  La donnée du jour (atelier 10) : un client professionnel ouvert ce matin,
  Côté Livraisons à Mérignac, et ses 250 trajets du vendredi 23 octobre
  2026. C'est ce que votre sauvegarde doit protéger.

.DESCRIPTION
  Sans option, le script ajoute ce client et ses trajets dans la base de
  dev, s'ils n'y sont pas déjà (relancé, il n'ajoute rien), puis affiche ce
  qu'il faut retrouver après la restauration : le nombre de trajets et leur
  empreinte, calculée par PostgreSQL sur toutes leurs valeurs.

  Avec -Verifier, il n'ajoute rien : il mesure seulement ce que contient la
  base, et le compare à ce qui est attendu. C'est la commande à lancer après
  la panne, puis après la restauration.

.EXAMPLE
  .\scripts\donnees-du-jour.ps1
  .\scripts\donnees-du-jour.ps1 -Verifier
  pwsh ./scripts/donnees-du-jour.ps1 -Verifier      # macOS, Linux
#>
param(
    [ValidateSet("dev")][string]$Env = "dev",
    [switch]$Verifier
)
. "$PSScriptRoot/commun.ps1"

$ns = "velocite-$Env"
if (-not $Verifier) { Invoke-Sql $ns $DuJourAjout | Out-Null }
$mesure = (Invoke-Sql $ns $DuJourMesure | Select-Object -Last 1).Trim()
$nombre, $empreinte = $mesure -split " ", 2

Write-Host ""
Write-Host "Donnée du jour dans $ns :" -ForegroundColor Cyan
Write-Host ("  client     {0}" -f $DuJourClient)
Write-Host ("  trajets    {0}" -f $nombre)
Write-Host ("  empreinte  {0}" -f $empreinte)
Write-Host ""
if ([int]$nombre -eq 0) {
    Write-Host "Aucun trajet du client : la donnée du jour n'est pas dans cette base." `
        -ForegroundColor Yellow
} elseif ([int]$nombre -eq $DuJourTrajets -and $empreinte -eq $DuJourEmpreinte) {
    Write-Host "C'est bien la donnée du jour : $DuJourTrajets trajets, empreinte $DuJourEmpreinte." `
        -ForegroundColor Green
    if (-not $Verifier) {
        Write-Host "Notez ces deux valeurs dans docs/RUNBOOK.md : la restauration doit les rendre."
    }
} else {
    Write-Host "Attendu : $DuJourTrajets trajets, empreinte $DuJourEmpreinte. La donnée du jour est abîmée." `
        -ForegroundColor Red
}
