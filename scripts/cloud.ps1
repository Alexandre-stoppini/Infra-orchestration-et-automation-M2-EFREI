<#
.SYNOPSIS
  VéloCité chez Hetzner : le même dépôt, une autre couche 00. Quatre étapes.

.DESCRIPTION
  monter     D'abord verifier.ps1 -Atelier 11 -AvantMonter : au moindre KO,
             rien n'est créé. Puis infra\00-cloud-hetzner : pare-feu,
             serveur, k3s ; le contexte kubectl "hetzner-<equipe>" est
             ajouté à ~\.kube\config.
  deployer   Le code de app\ part sur la machine (sans app\secrets), les images
             y sont construites et chargées dans k3s. Puis infra\20-env et
             deploy\overlays\dev, SANS MODIFICATION, sur ce contexte.
  verifier   L'API répond depuis le poste, certificat vérifié.
  detruire   Tout disparaît : machine, pare-feu, clé, contexte kubectl. Chez
             Hetzner, une machine éteinte reste facturée : seule cette étape
             arrête la facture.

  Avant la première étape, dans ce PowerShell (une fois par terminal) :
    $s = Read-Host -AsSecureString "Token Hetzner"
    $env:HCLOUD_TOKEN = [Net.NetworkCredential]::new("", $s).Password
    $env:TF_VAR_eleve = "velocite-equipe3"     # le numéro de votre équipe
    $env:TF_VAR_phrase_etat = Read-Host "Phrase du state"

.EXAMPLE
  .\scripts\cloud.ps1 -Etape monter
  .\scripts\cloud.ps1 -Etape deployer
  .\scripts\cloud.ps1 -Etape verifier
  .\scripts\cloud.ps1 -Etape detruire
#>
param(
    [Parameter(Mandatory)][ValidateSet("monter", "deployer", "verifier", "detruire")][string]$Etape
)
. "$PSScriptRoot/commun.ps1"

Test-PhraseEtat
if (-not $env:TF_VAR_eleve) { throw "Définissez `$env:TF_VAR_eleve = `"velocite-equipeN`" (le numéro de votre équipe)." }
$Couche = "$Racine/infra/00-cloud-hetzner"
$Copie20 = "$Racine/infra/00-cloud-hetzner/.env-cloud"   # copie de infra/20-env, state à part
$Contexte = "hetzner-$($env:TF_VAR_eleve)"
$Cle = "$Couche/.cles/$($env:TF_VAR_eleve)"
$Hote = "root"   # l'image Ubuntu de Hetzner n'a que root

function Get-Ip { (tofu "-chdir=$Couche" output -raw ip_publique).Trim() }

function Invoke-Distant([string]$Commande) {
    Invoke-Commande ssh -i $Cle -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$Hote@$(Get-Ip)" $Commande
}

switch ($Etape) {

    "monter" {
        if (-not $env:HCLOUD_TOKEN) { throw "Token Hetzner absent : voir l'aide, Get-Help ./scripts/cloud.ps1" }
        $ip = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
        Write-Host "Adresse autorisée : $ip/32"
        # La vérification d'avant : au moindre KO, on s'arrête ici, sans rien
        # créer chez Hetzner.
        & "$PSScriptRoot/verifier.ps1" -Atelier 11 -AvantMonter -MonIp $ip
        if ($LASTEXITCODE -ne 0) {
            throw "La vérification d'avant montage a des KO : rien n'a été créé chez Hetzner. Corrigez-les (chaque KO dit où regarder), puis relancez monter."
        }
        Invoke-Etape "Pare-feu, machine, k3s (infra/00-cloud-hetzner)" {
            Invoke-Commande tofu "-chdir=$Couche" init -input=false
            Invoke-Commande tofu "-chdir=$Couche" apply -input=false "-var=mon_ip=$ip/32"
            # OpenSSH refuse une clé privée lisible par d'autres comptes
            # ("UNPROTECTED PRIVATE KEY FILE") : sous C:\cours, elle hérite
            # des droits du disque. On ne garde que les vôtres.
            # Sous macOS, OpenTofu pose déjà les droits 0600.
            if ($SurWindows) {
                $chemin = [System.IO.Path]::GetFullPath($Cle)
                Invoke-Commande icacls $chemin /inheritance:r /grant:r "$($env:USERNAME):(F)"
            }
        }
        Invoke-Etape "Attente de k3s sur la machine" {
            $limite = (Get-Date).AddMinutes(8)
            do {
                Start-Sleep -Seconds 15
                Invoke-Silencieux ssh -i $Cle -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$Hote@$(Get-Ip)" "test -f /var/lib/velocite-pret"
            } until ($LASTEXITCODE -eq 0 -or (Get-Date) -gt $limite)
            if ($LASTEXITCODE -ne 0) { throw "k3s n'est pas prêt après 8 minutes. Essayez : ssh -i $Cle $Hote@$(Get-Ip) ; si ssh répond UNPROTECTED PRIVATE KEY FILE, ce sont les droits du fichier de clé ; sinon, sur la machine : tail /var/log/cloud-init-output.log" }
        }
        Invoke-Etape "Contexte kubectl $Contexte" {
            # Le kubeconfig de k3s vise 127.0.0.1 et s'appelle "default" : on le
            # réécrit, puis on le fusionne dans ~\.kube\config (lu par 20-env).
            $brut = (Invoke-Distant "sudo cat /etc/rancher/k3s/k3s.yaml") -join "`n"
            $brut = $brut.Replace("https://127.0.0.1:6443", "https://$(Get-Ip):6443").Replace(": default", ": $Contexte")
            $fichier = "$Couche/.cles/kubeconfig"
            [System.IO.File]::WriteAllText($fichier, $brut)
            $principal = Join-Path $HOME ".kube/config"
            if (Test-Path $principal) { Copy-Item $principal "$principal.avant-cloud" -Force }
            $env:KUBECONFIG = $principal + [System.IO.Path]::PathSeparator + $fichier
            $fusion = (kubectl config view --flatten) -join "`n"
            Remove-Item Env:\KUBECONFIG
            [System.IO.File]::WriteAllText($principal, $fusion)
            Invoke-Commande kubectl --context $Contexte get nodes -o wide
        }
    }

    "deployer" {
        Invoke-Etape "Code de l'application vers la machine" {
            $archive = Join-Path ([System.IO.Path]::GetTempPath()) "app.tgz"
            Invoke-Commande tar -czf $archive --exclude=secrets -C $Racine app
            Invoke-Commande scp -i $Cle -o StrictHostKeyChecking=accept-new $archive "$Racine/scripts/cloud/construire-images.sh" "$Hote@$(Get-Ip):"
            Remove-Item $archive
        }
        Invoke-Etape "Images construites sur la machine, chargées dans k3s" {
            # Le script part dans un fichier : passé en argument à ssh, un script
            # de plusieurs lignes serait réinterprété par PowerShell 5.1.
            Invoke-Distant "bash construire-images.sh"
        }
        Invoke-Etape "Environnement dev (copie de infra/20-env, state à part)" {
            if (Test-Path $Copie20) { Remove-Item $Copie20 -Recurse -Force }
            New-Item -ItemType Directory -Path $Copie20 | Out-Null
            Get-ChildItem "$Racine/infra/20-env" -Exclude ".terraform", "terraform.tfstate*", "*.tfstate" |
                Copy-Item -Destination $Copie20 -Recurse
            Invoke-Commande tofu "-chdir=$Copie20" init -input=false
            Invoke-Commande tofu "-chdir=$Copie20" workspace select -or-create dev
            Invoke-Commande tofu "-chdir=$Copie20" apply -input=false -auto-approve "-var-file=envs/dev.tfvars" "-var=contexte_kubectl=$Contexte"
        }
        Invoke-Etape "Applications (deploy/overlays/dev, inchangé)" {
            Invoke-Commande kubectl --context $Contexte apply -k "$Racine/deploy/overlays/dev"
            Invoke-Commande kubectl --context $Contexte -n velocite-dev rollout status statefulset/postgres --timeout=300s
            Invoke-Commande kubectl --context $Contexte -n velocite-dev rollout status statefulset/garage --timeout=300s
            foreach ($d in "redis", "api", "ingest", "nginx", "loadgen") {
                Invoke-Commande kubectl --context $Contexte -n velocite-dev rollout status "deployment/$d" --timeout=300s
            }
        }
        Show-Releve
    }

    "verifier" {
        $ca = "$Couche/.cles/ca-cloud.crt"
        [System.IO.File]::WriteAllText($ca, ((tofu "-chdir=$Copie20" output -raw certificat_ac) -join "`n"))
        # Le certificat du frontal est émis pour "localhost" : --resolve fait
        # aboutir ce nom sur la machine Hetzner, et le certificat reste vérifié.
        Invoke-Commande $Curl -sS @CurlTls --cacert $ca --resolve "localhost:30443:$(Get-Ip)" https://localhost:30443/api/version
        Write-Host ""
        Invoke-Commande kubectl --context $Contexte -n velocite-dev get pods
    }

    "detruire" {
        Invoke-Etape "Destruction (infra/00-cloud-hetzner)" {
            Invoke-Commande tofu "-chdir=$Couche" destroy -input=false -auto-approve "-var=mon_ip=0.0.0.0/32"
        }
        Invoke-Silencieux kubectl config delete-context $Contexte
        Invoke-Silencieux kubectl config delete-cluster $Contexte
        Invoke-Silencieux kubectl config delete-user $Contexte
        if (Test-Path $Copie20) { Remove-Item $Copie20 -Recurse -Force }
        Write-Host "Détruit. Vérifiez par l'API (Fiche_Atelier11_J5, partie 2, étape 3) : aucun serveur $($env:TF_VAR_eleve). La facture s'arrête." -ForegroundColor Green
    }
}
