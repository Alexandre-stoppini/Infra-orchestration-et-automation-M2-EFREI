<#
.SYNOPSIS
  Installe les outils du module, à version fixe, empreinte vérifiée :
  kind, OpenTofu, kubectl, argo. Windows (PowerShell 5.1 ou 7), macOS
  (PowerShell 7, processeur Intel ou Apple) et Linux (PowerShell 7,
  processeur Intel ou AMD).

.DESCRIPTION
  Les exécutables vont dans le dossier velocite-outils de votre profil (pas
  besoin d'être administrateur). Un fichier dont l'empreinte SHA-256 ne
  correspond pas est supprimé, rien n'est installé. Les empreintes sont
  celles publiées par chaque projet (relevées le 13 octobre 2026).
  Docker Desktop s'installe à part (docs/DEPLOIEMENT.md).

.EXAMPLE
  ./scripts/installer-outils.ps1
  # puis fermez et rouvrez PowerShell
#>
param([string]$Dossier = (Join-Path $HOME "velocite-outils"))
$ErrorActionPreference = "Stop"
$SurWindows = $env:OS -eq "Windows_NT"
if ($SurWindows) {
    # Windows PowerShell 5.1 négocie parfois encore TLS 1.0 par défaut.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

if ($SurWindows) {
    $outils = @(
        @{ Nom = "kind.exe"; Url = "https://kind.sigs.k8s.io/dl/v0.33.0/kind-windows-amd64"
           Empreinte = "4b22adaa135368c5a465d56bbd8e520cbea87272a06ca00b6078e7b81515c9fc"; Format = "brut" },
        @{ Nom = "tofu.exe"; Url = "https://github.com/opentofu/opentofu/releases/download/v1.13.1/tofu_1.13.1_windows_amd64.zip"
           Empreinte = "5b653d1d95719eeec4ccf55f0e2102081b6f589d788197f1cabeb89cbd4078a7"; Format = "zip" },
        @{ Nom = "kubectl.exe"; Url = "https://dl.k8s.io/release/v1.37.1/bin/windows/amd64/kubectl.exe"
           Empreinte = "14b93c4916a6f37a06fbc1f46b0a1d2404c4f9741be09f00d6caf8af3b05f1d3"; Format = "brut" },
        @{ Nom = "argo.exe"; Url = "https://github.com/argoproj/argo-workflows/releases/download/v4.1.5/argo-windows-amd64.exe.gz"
           Empreinte = "c48cb200502615dd67ea0e154e45e933cdd64a3948394e03b6d15bc8580eb278"; Format = "gz" }
    )
} else {
    $SurLinux = (uname -s) -eq "Linux"
    if ($SurLinux -and (uname -m) -ne "x86_64") { throw "Sous Linux, ce script couvre les processeurs Intel et AMD (x86_64)." }
    # arm64 : processeur Apple (M1 et suivants) ; x86_64 : processeur Intel.
    $arm = (uname -m) -eq "arm64"
    $a = if ($arm) { "arm64" } else { "amd64" }
    $e = if ($arm) {
        @{ kind = "0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f"
           tofu = "81aebe6453223bcb3ce3c28424b36d009ebfddd3ad65ad1ec3eed0d0d574a77b"
           kubectl = "fd65982c97ddad3106754b69ffa196d0e543aa591930ae52aed1adfb92f8c77f"
           argo = "cd76f14ca024247323a56e55b0c9ca5c9ee3510607e9ea0fe833d0a329044e03" }
    } else {
        @{ kind = "5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0"
           tofu = "d44ab59ec53fb18e900f4ae3fc8b72e042c9e03ca957860edbaac04e4427218d"
           kubectl = "6851381c486ff6edd691623e3d65c87cb9a5b02887ff8fbbb38d8a031b748387"
           argo = "79ea9f4d7503c32aea79d40a0e2f78a36a7bb814c4bd3dd644e0185dd2f4f89a" }
    }
    # Linux : empreintes publiées par chaque projet, relevées le 19 octobre 2026.
    if ($SurLinux) {
        $e = @{ kind = "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d"
                tofu = "8ccbc6f8ee21d2827715f3c6e08a9b3e0209b1e62057c05067ef117e047c1a80"
                kubectl = "65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"
                argo = "ab78728d3bcd029f0e8547736e2f3c69d2519a134a3f9ee74454ededa14af36c" }
    }
    $os = if ($SurLinux) { "linux" } else { "darwin" }
    $outils = @(
        @{ Nom = "kind"; Url = "https://kind.sigs.k8s.io/dl/v0.33.0/kind-$os-$a"
           Empreinte = $e.kind; Format = "brut" },
        @{ Nom = "tofu"; Url = "https://github.com/opentofu/opentofu/releases/download/v1.13.1/tofu_1.13.1_$($os)_$a.zip"
           Empreinte = $e.tofu; Format = "zip" },
        @{ Nom = "kubectl"; Url = "https://dl.k8s.io/release/v1.37.1/bin/$os/$a/kubectl"
           Empreinte = $e.kubectl; Format = "brut" },
        @{ Nom = "argo"; Url = "https://github.com/argoproj/argo-workflows/releases/download/v4.1.5/argo-$os-$a.gz"
           Empreinte = $e.argo; Format = "gz" }
    )
}

New-Item -ItemType Directory -Force -Path $Dossier | Out-Null
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "velocite-outils"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

foreach ($o in $outils) {
    $fichier = Join-Path $tmp ([System.IO.Path]::GetFileName($o.Url))
    Write-Host "Téléchargement de $($o.Nom)"
    Invoke-WebRequest -Uri $o.Url -OutFile $fichier -UseBasicParsing
    $calcule = (Get-FileHash -Algorithm SHA256 -Path $fichier).Hash.ToLower()
    if ($calcule -ne $o.Empreinte) {
        Remove-Item $fichier
        throw "Empreinte inattendue pour $($o.Nom) : $calcule. Rien n'est installé."
    }
    $cible = Join-Path $Dossier $o.Nom
    switch ($o.Format) {
        "brut" { Copy-Item $fichier $cible -Force }
        "zip" {
            $dest = Join-Path $tmp "zip"
            Expand-Archive -Path $fichier -DestinationPath $dest -Force
            Copy-Item (Join-Path $dest $o.Nom) $cible -Force
        }
        "gz" {
            $entree = [System.IO.File]::OpenRead($fichier)
            $sortie = [System.IO.File]::Create($cible)
            $gz = New-Object System.IO.Compression.GZipStream($entree, [System.IO.Compression.CompressionMode]::Decompress)
            $gz.CopyTo($sortie)
            $gz.Dispose(); $sortie.Dispose(); $entree.Dispose()
        }
    }
    if (-not $SurWindows) { chmod 755 $cible }
    Write-Host "    empreinte vérifiée, installé dans $cible"
}
Remove-Item $tmp -Recurse -Force

if ($SurWindows) {
    $chemin = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($chemin -split ";") -notcontains $Dossier) {
        [Environment]::SetEnvironmentVariable("Path", "$chemin;$Dossier", "User")
    }
}

# Docker Desktop installe son propre kubectl, plus ancien, qui passe avant
# le vôtre. Les scripts du dépôt corrigent l'ordre pour eux-mêmes ; pour vos
# commandes tapées à la main, une ligne dans votre profil PowerShell, ajoutée
# une seule fois, met velocite-outils en tête.
$ligne = '$env:PATH = (Join-Path $HOME "velocite-outils") + [System.IO.Path]::PathSeparator + $env:PATH'
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (-not (Select-String -Path $PROFILE -SimpleMatch "velocite-outils" -Quiet)) {
    Add-Content -Path $PROFILE -Value $ligne
    Write-Host "Ligne ajoutée à votre profil PowerShell : $PROFILE"
}
# macOS et Linux : la même ligne pour le Terminal (zsh sous macOS, bash sous
# Linux), pour les commandes tapées hors de PowerShell.
if (-not $SurWindows) {
    $rc = if ($SurLinux) { Join-Path $HOME ".bashrc" } else { Join-Path $HOME ".zshrc" }
    if (-not (Test-Path $rc) -or -not (Select-String -Path $rc -SimpleMatch "velocite-outils" -Quiet)) {
        Add-Content -Path $rc -Value 'export PATH="$HOME/velocite-outils:$PATH"'
        Write-Host "Ligne ajoutée à $rc"
    }
}
# Windows : kubectl diff appelle un programme "diff" que Windows n'a pas. Git
# pour Windows en fournit un ; sans lui, kubectl diff se tait quand il n'y a
# pas d'écart et n'échoue qu'au premier écart, c'est-à-dire en plein incident.
if ($SurWindows) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $outilsGit = Join-Path (Split-Path (Split-Path $git.Source)) "usr\bin"
        if ((Test-Path (Join-Path $outilsGit "diff.exe")) -and
            -not (Select-String -Path $PROFILE -SimpleMatch "usr\bin" -Quiet)) {
            Add-Content -Path $PROFILE -Value "`$env:PATH += `";$outilsGit`""
            Write-Host "Le diff de Git pour Windows ajouté à votre profil (pour kubectl diff)."
        }
    } else {
        Write-Host "Git pour Windows est absent : installez-le, puis relancez ce script." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Fermez et rouvrez PowerShell (ou le Terminal), puis vérifiez :"
Write-Host "  kind version ; tofu version ; kubectl version --client ; argo version --short"
Write-Host "  (Get-Command kubectl).Source    # doit être dans velocite-outils"
