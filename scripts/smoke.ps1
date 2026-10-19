<#
.SYNOPSIS
  Tests de fumée d'un environnement VéloCité déployé : le service répond,
  le durcissement tient.

.DESCRIPTION
  Chaque contrôle affiche OK ou KO. Le script sort en code 1 au premier KO
  si -Strict, sinon à la fin s'il y en a eu un.

.EXAMPLE
  .\scripts\smoke.ps1 -Env dev
#>
param(
    [ValidateSet("dev", "prod")][string]$Env = "dev",
    [switch]$Strict,
    # Pendant un retour arrière en cours, un pod de la nouvelle version plante
    # par définition : on saute ce seul contrôle, le service doit tenir.
    [switch]$PendantIncident
)
. "$PSScriptRoot/commun.ps1"

$ns = "velocite-$Env"
$port = if ($Env -eq "dev") { 8443 } else { 9443 }
$base = "https://localhost:$port"
$ca = Join-Path ([System.IO.Path]::GetTempPath()) "velocite-ca-$Env.crt"
$ko = 0

# On lit les sorties de l'environnement, puis on remet le workspace tel qu'on
# l'a trouvé : un tofu output tapé ensuite à la main viserait sinon le mauvais.
$wsAvant = (tofu "-chdir=$Racine/infra/20-env" workspace show).Trim()
Invoke-Silencieux tofu "-chdir=$Racine/infra/20-env" workspace select $Env
tofu "-chdir=$Racine/infra/20-env" output -raw certificat_ac | Set-Content -Path $ca -Encoding ascii
$mdp = tofu "-chdir=$Racine/infra/20-env" output -json mots_de_passe_comptes | ConvertFrom-Json
Invoke-Silencieux tofu "-chdir=$Racine/infra/20-env" workspace select $wsAvant

function Test-Controle {
    param([string]$Nom, [scriptblock]$Essai)
    $ok = $false
    try { $ok = [bool](& $Essai) } catch { $ok = $false }
    $etiquette = if ($ok) { "OK" } else { "KO" }
    $couleur = if ($ok) { "Green" } else { "Red" }
    Write-Host ("{0,-3} {1}" -f $etiquette, $Nom) -ForegroundColor $couleur
    if (-not $ok) {
        $script:ko++
        if ($Strict) { throw "Contrôle en échec : $Nom" }
    }
}

# curl et non Invoke-WebRequest : il vérifie le certificat avec notre
# autorité (--cacert), sans toucher au magasin de certificats de Windows.
function Get-Code {
    param([string]$Chemin, [string[]]$En = @())
    $code = & $Curl -s -o $Nul -w "%{http_code}" --cacert $ca @CurlTls @En "$base$Chemin"
    return [int]$code
}

function Get-Jeton {
    param([string]$Email, [string]$Mdp)
    $corps = @{ email = $Email; password = $Mdp } | ConvertTo-Json -Compress
    $fichier = Join-Path ([System.IO.Path]::GetTempPath()) "velocite-login.json"
    Set-Content -Path $fichier -Value $corps -Encoding ascii
    $r = & $Curl -s --cacert $ca @CurlTls -H "Content-Type: application/json" --data-binary "@$fichier" "$base/api/login"
    Remove-Item $fichier
    return ($r | ConvertFrom-Json).token
}

Write-Host "Tests de fumée sur $base ($ns)"

Test-Controle "Le frontal répond en TLS, certificat vérifié" { (Get-Code "/api/version") -eq 200 }
Test-Controle "TLS 1.1 refusé par le frontal" {
    & $Curl -s -o $Nul --cacert $ca @CurlTls --tls-max 1.1 "$base/api/version" 2>$null
    $LASTEXITCODE -ne 0
}
Test-Controle "La version annonce l'environnement $Env" {
    (& $Curl -s --cacert $ca @CurlTls "$base/api/version" | ConvertFrom-Json).environnement -eq $Env
}
Test-Controle "Route protégée sans token : 401" { (Get-Code "/api/trips") -eq 401 }

$jetonDs = Get-Jeton "datasci@velocite.example" $mdp.datasci_password
Test-Controle "Connexion du compte data science" { [bool]$jetonDs }
Test-Controle "Statistiques par région accessibles au rôle datascientist" {
    (Get-Code "/api/stats/regions" @("-H", "Authorization: Bearer $jetonDs")) -eq 200
}
Test-Controle "Pièce d'identité refusée au rôle datascientist : 403" {
    (Get-Code "/api/users/7/kyc" @("-H", "Authorization: Bearer $jetonDs")) -eq 403
}

$jetonSupport = Get-Jeton "support@velocite.example" $mdp.support_password
Test-Controle "Pièce d'identité servie au rôle support" {
    (Get-Code "/api/users/7/kyc" @("-H", "Authorization: Bearer $jetonSupport")) -eq 200
}

if ($PendantIncident) {
    Write-Host "--  Pods prêts : contrôle sauté pendant l'incident" -ForegroundColor DarkGray
} else {
    # Les pods d'un bilan en échec restent 7 jours pour l'enquête : ils
    # relèvent de argo list, pas de la santé des services.
    Test-Controle "Tous les pods des services de $ns sont prêts ou terminés" {
        $pods = kubectl -n $ns get pods -o json | ConvertFrom-Json
        $enDefaut = @($pods.items | Where-Object {
            $etiquettes = @()
            if ($_.metadata.labels) { $etiquettes = $_.metadata.labels.PSObject.Properties.Name }
            $etiquettes -notcontains "workflows.argoproj.io/workflow" -and
            $_.status.phase -ne "Succeeded" -and
            -not ($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" })
        })
        $enDefaut.Count -eq 0
    }
}
Test-Controle "Namespace $ns en Pod Security restricted" {
    (kubectl get namespace $ns -o jsonpath="{.metadata.labels.pod-security\.kubernetes\.io/enforce}") -eq "restricted"
}
Test-Controle "Aucun conteneur de $ns ne tourne en root" {
    $uids = kubectl -n $ns get pods -o jsonpath="{range .items[*]}{.spec.securityContext.runAsUser}{'\n'}{end}"
    -not ($uids | Where-Object { $_ -eq "0" -or $_ -eq "" })
}
Test-Controle "PostgreSQL injoignable depuis un pod non autorisé (NetworkPolicy)" {
    # Un pod jetable, sans l'étiquette d'un service autorisé : la politique
    # réseau doit lui fermer PostgreSQL. Manifeste complet, parce que le
    # namespace refuse tout pod qui ne déclare pas son contexte de sécurité.
    $sonde = @"
apiVersion: v1
kind: Pod
metadata:
  name: sonde-reseau
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: sonde
      image: mirror.gcr.io/library/busybox:1.37
      command: [sh, -c, "nc -w 3 postgres 5432 </dev/null && echo OUVERT || echo FERME"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      resources:
        limits: {cpu: 100m, memory: 32Mi}
"@
    Invoke-Silencieux kubectl -n $ns delete pod sonde-reseau --ignore-not-found
    $sonde | kubectl -n $ns apply -f - *> $null
    Invoke-Silencieux kubectl -n $ns wait pod/sonde-reseau --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s
    $sortie = kubectl -n $ns logs sonde-reseau 2>$null
    Invoke-Silencieux kubectl -n $ns delete pod sonde-reseau --wait=false
    ($sortie -join "") -match "FERME"
}

Remove-Item $ca -ErrorAction SilentlyContinue
Write-Host ""
if ($ko -gt 0) {
    Write-Host "$ko contrôle(s) en échec." -ForegroundColor Red
    exit 1
}
Write-Host "Tous les contrôles sont passés." -ForegroundColor Green
