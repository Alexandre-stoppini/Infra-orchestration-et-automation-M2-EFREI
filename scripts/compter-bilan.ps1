<#
.SYNOPSIS
  Compte les lignes du bilan quotidien d'un jour, dans la base d'un
  environnement. La preuve de l'idempotence : compter, relancer le même jour,
  compter encore ; le nombre ne doit pas bouger.

.EXAMPLE
  .\scripts\compter-bilan.ps1
  .\scripts\compter-bilan.ps1 -Date 2026-03-12 -Env dev
  pwsh ./scripts/compter-bilan.ps1          # macOS, Linux

  Le mot de passe est lu à l'intérieur du pod : rien ne s'affiche à l'écran.
#>
param(
    [ValidateSet("dev", "prod")][string]$Env = "dev",
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$Date = "2026-03-12"
)
. "$PSScriptRoot/commun.ps1"

$requete = "SELECT count(*) FROM daily_region_stats WHERE jour = '$Date';"
$sortie = $requete | & kubectl -n "velocite-$Env" exec -i statefulset/postgres -- `
    sh -c 'PGPASSWORD=$(cat /run/secrets/postgres_password) psql -U postgres -d velocite -At'
if ($LASTEXITCODE -ne 0) { throw "La base de velocite-$Env ne répond pas : kubectl -n velocite-$Env get pods" }
Write-Host ("Lignes du {0} dans velocite-{1} : {2}" -f $Date, $Env, ($sortie | Select-Object -Last 1))
