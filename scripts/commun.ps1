# Fonctions partagées par les scripts de ce dossier. Chargé par :
#   . "$PSScriptRoot/commun.ps1"
#
# Compatible Windows PowerShell 5.1 et PowerShell 7.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Racine = Split-Path -Parent $PSScriptRoot

# Les scripts tournent sous Windows (le poste) et sous Linux (la CI). Les
# chemins utilisent "/", que Windows accepte aussi. Seuls curl et le fichier
# vide diffèrent : sous Windows, "curl" est un alias de PowerShell, il faut
# appeler curl.exe.
$SurWindows = $env:OS -eq "Windows_NT"
$Curl = if ($SurWindows) { "curl.exe" } else { "curl" }
$Nul = if ($SurWindows) { "NUL" } else { "/dev/null" }

# Les outils du module passent devant ceux de Docker Desktop : son dossier est
# dans le PATH système, qui précède toujours le PATH utilisateur, et son
# kubectl est plus ancien que le cluster. Pour ce script seulement.
$outilsModule = Join-Path $HOME "velocite-outils"
if (Test-Path $outilsModule) { $env:PATH = $outilsModule + [System.IO.Path]::PathSeparator + $env:PATH }

# Le curl.exe de Windows (Schannel) veut vérifier la révocation du
# certificat, et notre autorité de test ne publie pas de liste de
# révocation. On garde la vérification par --cacert, on saute seulement
# la révocation.
[string[]]$CurlTls = @()
if ($SurWindows) { $CurlTls = @("--ssl-no-revoke") }

# kubectl diff appelle un programme "diff", absent de Windows. Git pour
# Windows en fournit un (usr\bin\diff.exe) : on l'ajoute en fin de PATH,
# pour ce script seulement, sans masquer les commandes de Windows.
if ($SurWindows -and -not (Get-Command diff.exe -ErrorAction SilentlyContinue)) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $outilsGit = Join-Path (Split-Path (Split-Path $git.Source)) "usr\bin"
        if (Test-Path (Join-Path $outilsGit "diff.exe")) { $env:Path += ";$outilsGit" }
    }
}

# Lance une commande externe et s'arrête si elle échoue. PowerShell 5.1 ne
# le fait pas tout seul : une commande native en échec ne lève pas d'erreur,
# elle positionne seulement $LASTEXITCODE.
# Fonction volontairement simple (sans param) : les options comme
# -input=false ou --timeout=300s passent telles quelles dans $args.
function Invoke-Commande {
    $programme = $args[0]
    [string[]]$reste = @()
    if ($args.Count -gt 1) { $reste = $args[1..($args.Count - 1)] }
    & $programme @reste
    if ($LASTEXITCODE -ne 0) {
        throw "Échec ($LASTEXITCODE) : $programme $($reste -join ' ')"
    }
}

# Lance une commande externe dont on veut seulement le code de retour
# ($LASTEXITCODE), sorties jetées. Windows PowerShell 5.1 transforme la
# sortie d'erreur redirigée d'une commande externe en erreur PowerShell, qui
# arrête le script ($ErrorActionPreference = "Stop") : "kubectl ... *> $null"
# s'interromprait justement quand on teste un échec attendu.
function Invoke-Silencieux {
    $programme = $args[0]
    [string[]]$reste = @()
    if ($args.Count -gt 1) { $reste = $args[1..($args.Count - 1)] }
    $avant = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $programme @reste *> $null } finally { $ErrorActionPreference = $avant }
}

# Exécute un bloc, mesure sa durée, l'ajoute au relevé.
$script:Releve = [System.Collections.Generic.List[object]]::new()
function Invoke-Etape {
    param([Parameter(Mandatory)][string]$Nom,
          [Parameter(Mandatory)][scriptblock]$Bloc)
    Write-Host ""
    Write-Host "==> $Nom" -ForegroundColor Cyan
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()
    & $Bloc
    $chrono.Stop()
    $script:Releve.Add([pscustomobject]@{
        Etape = $Nom; Secondes = [math]::Round($chrono.Elapsed.TotalSeconds)
    })
    Write-Host ("    terminé en {0:n0} s" -f $chrono.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

function Show-Releve {
    Write-Host ""
    $script:Releve | Format-Table -AutoSize | Out-Host
    $total = ($script:Releve | Measure-Object -Property Secondes -Sum).Sum
    Write-Host ("Total : {0} min {1:00} s" -f [math]::Floor($total / 60), ($total % 60)) -ForegroundColor Green
}

function Test-Prerequis {
    param([string[]]$Outils)
    $manquants = @($Outils | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($manquants.Count -gt 0) {
        throw "Outils absents du PATH : $($manquants -join ', '). Voir docs/DEPLOIEMENT.md."
    }
    Invoke-Silencieux docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw "Docker ne répond pas : Docker Desktop est-il démarré ?" }
    # Kubernetes refuse de démarrer sur un moteur en cgroup v1 : la création
    # du cluster échouerait plus loin avec quarante lignes d'erreur kubeadm.
    $cgroup = docker info --format '{{.CgroupVersion}}'
    if ($cgroup -ne "2") {
        throw @"
Docker tourne en cgroup v$cgroup : Kubernetes ne démarrera pas.
  1. Mettez Docker Desktop à jour (menu Docker Desktop, Check for updates).
  2. Si docker info --format '{{.CgroupVersion}}' répond encore 1, créez
     le fichier $HOME\.wslconfig avec ces deux lignes :
         [wsl2]
         kernelCommandLine = cgroup_no_v1=all
     puis : wsl --shutdown, et relancez Docker Desktop.
Voir docs/DEPLOIEMENT.md, section Prérequis.
"@
    }
}

function Test-PhraseEtat {
    if (-not $env:TF_VAR_phrase_etat) {
        throw "Phrase de passe du state absente. Faites d'abord : `$env:TF_VAR_phrase_etat = Read-Host 'Phrase du state'"
    }
}
