<#
.SYNOPSIS
  Détruit le cluster kind de VéloCité, et avec lui tous les environnements.

.DESCRIPTION
  Les states des couches 10 et 20 décrivent des objets qui n'existent plus
  une fois le cluster détruit : on les vide aussi, sinon le prochain up
  croirait qu'ils existent encore. Les states sont des fichiers locaux
  chiffrés ; rien d'autre n'est effacé.

.EXAMPLE
  .\scripts\down.ps1
#>
param([switch]$Force)
. "$PSScriptRoot/commun.ps1"

if (-not $Force) {
    $r = Read-Host "Détruire le cluster kind-velocite et tous ses environnements ? (oui/non)"
    if ($r -ne "oui") { Write-Host "Rien n'a été fait."; return }
}
Test-PhraseEtat

Invoke-Etape "Destruction du cluster (infra/00-cluster)" {
    Invoke-Commande tofu "-chdir=$Racine/infra/00-cluster" destroy -input=false -auto-approve
}

Invoke-Etape "Oubli des objets disparus avec le cluster (states 10 et 20)" {
    foreach ($couche in "10-outils", "20-env") {
        $dossier = "$Racine/infra/$couche"
        foreach ($ws in "default", "dev", "prod") {
            $fichier = if ($ws -eq "default") { "$dossier/terraform.tfstate" }
                       else { "$dossier/terraform.tfstate.d/$ws/terraform.tfstate" }
            if (Test-Path $fichier) {
                Remove-Item $fichier -Force
                Write-Host "    state $couche ($ws) supprimé"
            }
        }
    }
}

Show-Releve
