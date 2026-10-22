<#
.SYNOPSIS
  Vérifie, atelier par atelier, que ce que demande la fiche est fait et
  fonctionne. Ne modifie rien.

.DESCRIPTION
  Un contrôle par exigence de la fiche de l'atelier : un fichier écrit, une
  valeur dans le cluster, un service qui répond, un diff vide. Chaque ligne
  dit OK ou KO ; un KO dit où regarder. Le script sort en code 1 s'il y a eu
  au moins un KO.

  Aucune phrase du state n'est demandée, sauf pour -Atelier 12 (la
  préparation du 30 novembre) : ses contrôles lancent tofu plan, qui lit des
  states chiffrés ($env:TF_VAR_phrase_etat). Le reste se lit dans le dépôt,
  dans le cluster (kubectl) et dans Docker.

.EXAMPLE
  .\scripts\verifier.ps1 -Atelier 7
  .\scripts\verifier.ps1 -Atelier 1,2,3,4,5,6
  .\scripts\verifier.ps1 -Atelier 9
  .\scripts\verifier.ps1 -Atelier 10
  .\scripts\verifier.ps1 -Atelier 11 -AvantMonter
  pwsh ./scripts/verifier.ps1 -Atelier 8          # macOS, Linux

  -Atelier 11 -AvantMonter : avant de créer la machine chez Hetzner, la
  couche infra/00-cloud-hetzner est-elle prête ? Le terminal (token,
  identifiant de l'équipe, phrase du state), les trois pièces complètes,
  fmt, validate, le token absent du dépôt, puis tofu plan lu en détail :
  rien n'est créé. scripts/cloud.ps1 -Etape monter le lance d'office.
#>
param(
    # Texte, puis découpé : "pwsh ./scripts/verifier.ps1 -Atelier 1,2,3" depuis
    # bash passe la liste comme un seul mot.
    [Parameter(Mandatory)][string[]]$Atelier,
    # Atelier 11 : les contrôles d'avant la création de la machine.
    [switch]$AvantMonter,
    # L'adresse du poste, déjà lue par cloud.ps1 ; sinon, api.ipify.org.
    [string]$MonIp
)
. "$PSScriptRoot/commun.ps1"
[int[]]$Atelier = @(($Atelier -join ",") -split "[,\s]+" | Where-Object { $_ } | ForEach-Object { [int]$_ })
if (@($Atelier | Where-Object { $_ -lt 1 -or $_ -gt 12 }).Count) { throw "Ateliers de 1 à 12 : -Atelier 9, ou -Atelier 1,2,3" }
Set-Location $Racine

$script:ko = 0
$script:total = 0

# ------------------------------------------------------------------ outils
function Controle {
    param([string]$Nom, [scriptblock]$Essai, [string]$Piste)
    $script:total++
    $ok = $false
    try { $ok = [bool](& $Essai) } catch { $ok = $false }
    if ($ok) {
        Write-Host ("OK  {0}" -f $Nom) -ForegroundColor Green
    } else {
        $script:ko++
        Write-Host ("KO  {0}" -f $Nom) -ForegroundColor Red
        if ($Piste) { Write-Host ("      -> {0}" -f $Piste) -ForegroundColor DarkYellow }
    }
}

# Lance une commande externe et rend son code et sa sortie, sans jamais
# s'arrêter : sous PowerShell 5.1, la sortie d'erreur d'un programme externe
# arrêterait le script.
function Lancer {
    param([string]$Programme, [string[]]$Arguments, [string]$Entree)
    $avant = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Entree) { $sortie = $Entree | & $Programme @Arguments 2>$null }
        else { $sortie = & $Programme @Arguments 2>$null }
        $code = $LASTEXITCODE
    } catch { $sortie = @(); $code = 1 }
    finally { $ErrorActionPreference = $avant }
    return [pscustomobject]@{ Code = $code; Texte = (@($sortie) -join "`n") }
}

function Kube-Json {
    param([string[]]$Arguments)
    $r = Lancer kubectl ($Arguments + @("-o", "json"))
    if ($r.Code -ne 0 -or -not $r.Texte) { return $null }
    return $r.Texte | ConvertFrom-Json
}

function Propriete {
    param($Objet, [string]$Chemin)
    $v = $Objet
    foreach ($p in $Chemin.Split(".")) {
        if ($null -eq $v) { return $null }
        $m = $v.PSObject.Properties[$p]
        if (-not $m) { return $null }
        $v = $m.Value
    }
    return $v
}

function Texte {
    param([string]$Fichier)
    $chemin = Join-Path $Racine $Fichier
    if (-not (Test-Path $chemin)) { return "" }
    return [System.IO.File]::ReadAllText($chemin, [System.Text.Encoding]::UTF8)
}

# Les lignes utiles d'une section : sous son titre, ni titre, ni ligne vide,
# ni A FAIRE, ni ligne de tableau vide, ni ancre.
function Lignes-Section {
    param([string]$Contenu, [string]$Titre)
    $lignes = $Contenu -split "`r?`n"
    $dedans = $false
    $niveau = 0
    $utiles = [System.Collections.Generic.List[string]]::new()
    $code = $false
    foreach ($l in $lignes) {
        if ($l.TrimStart().StartsWith('```')) { $code = -not $code }
        if (-not $code -and $l -match '^(#+)\s+(.*)$') {
            $n = $Matches[1].Length
            if ($dedans -and $n -le $niveau) { break }
            if (-not $dedans -and $Matches[2] -like "*$Titre*") { $dedans = $true; $niveau = $n; continue }
        }
        if (-not $dedans) { continue }
        $t = $l.Trim()
        if (-not $t -or $t -match '^A FAIRE' -or $t -match '^\|[\s\|:-]*\|$' -or $t -match '^<a id=' -or $t -eq '---') { continue }
        $utiles.Add($t)
    }
    return , $utiles
}

# Une section est remplie si au moins deux de ses lignes utiles ne viennent
# pas du modèle distribué (le fichier tel qu'il était au tag du cours).
function Section-Remplie {
    param([string]$Fichier, [string]$Titre, [string]$Tag)
    $actuel = Lignes-Section (Texte $Fichier) $Titre
    $modele = [System.Collections.Generic.List[string]]::new()
    $m = Lancer git @("show", "$($Tag):$Fichier")
    if ($m.Code -eq 0) { $modele = Lignes-Section $m.Texte $Titre }
    $nouvelles = @($actuel | Where-Object { $modele -notcontains $_ })
    return $nouvelles.Count -ge 2
}

function Deploiement-Pret {
    param([string]$Ns, [string]$Nom)
    $d = Kube-Json @("-n", $Ns, "get", "deployment", $Nom)
    if (-not $d) { return $false }
    $voulu = Propriete $d "spec.replicas"
    $prets = Propriete $d "status.readyReplicas"
    return ($prets -ge 1) -and ($prets -ge $voulu)
}

function Statefulset-Pret {
    param([string]$Ns, [string]$Nom)
    $d = Kube-Json @("-n", $Ns, "get", "statefulset", $Nom)
    return $d -and ((Propriete $d "status.readyReplicas") -ge 1)
}

function Repond {
    param([int]$Port)
    $ca = Join-Path ([System.IO.Path]::GetTempPath()) "verifier-ca.crt"
    $ns = if ($Port -eq 8443) { "velocite-dev" } else { "velocite-prod" }
    $r = Lancer kubectl @("-n", $ns, "get", "configmap", "velocite-ca", "-o", "jsonpath={.data.ca\.crt}")
    if ($r.Code -ne 0 -or -not $r.Texte) { return $false }
    Set-Content -Path $ca -Value $r.Texte -Encoding ascii
    $c = Lancer $Curl (@("-s", "-o", $Nul, "-w", "%{http_code}", "--cacert", $ca) + $CurlTls + @("https://localhost:$Port/api/version"))
    return $c.Texte -eq "200"
}

function Diff-Vide {
    param([string]$Overlay)
    if (-not $kubeOk) { return $false }
    $r = Lancer kubectl @("diff", "-k", "deploy/overlays/$Overlay")
    return $r.Code -eq 0
}

function Titre {
    param([string]$T)
    Write-Host ""
    Write-Host "==> $T" -ForegroundColor Cyan
}

# ------------------------------------------------------------------ atelier 11, avant de monter
# -AvantMonter : tout ce qui se vérifie AVANT de créer quoi que ce soit chez
# Hetzner. scripts/cloud.ps1 -Etape monter le lance d'office et s'arrête au
# moindre KO : rien n'est créé, rien n'est facturé. Le token n'est jamais
# affiché ; le plan est écrit hors du dépôt, puis effacé.

# Comme Lancer, mais garde aussi la sortie d'erreur (les messages de tofu).
function Lancer-Tout {
    param([string]$Programme, [string[]]$Arguments)
    $avant = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # tofu écrit en UTF-8 : sans cela, Windows PowerShell 5.1 abîmerait les
    # accents des messages des garde-fous.
    $encodage = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $sortie = & $Programme @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } catch { $sortie = @("$_"); $code = 1 }
    finally {
        try { [Console]::OutputEncoding = $encodage } catch { }
        $ErrorActionPreference = $avant
    }
    return [pscustomobject]@{ Code = $code; Texte = (@($sortie) -join "`n") }
}

# Les lignes qui disent pourquoi tofu s'est arrêté : "Error: ..." et le
# message en français des garde-fous, sans le décor.
function Extraire-Erreurs {
    param([string]$Texte, [int]$Max = 4)
    # Le décor de tofu : traits verticaux et coins (U+2502, U+2575, U+2577),
    # traits horizontaux et embranchements (U+2500, U+251C).
    $bord = "^[\s" + [char]0x2502 + [char]0x2575 + [char]0x2577 + "]+"
    $trait = "^(on |with |\d+:|" + [char]0x2500 + "|" + [char]0x251C + "|System\.Management\.Automation)"
    $l = @($Texte -split "`r?`n" | ForEach-Object { ($_ -replace $bord, '').Trim() } |
        Where-Object { $_ -and $_ -notmatch $trait -and $_ -notmatch '^(local|var|self|path|each)\.\S* is ' -and $_ -notmatch '^(Diff:|[\[\]#+~"-])' })
    $garde = @()
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ($l[$i] -match '^Error:') {
            # Le titre de l'erreur, puis sa première phrase (pour un garde-fou :
            # le message en français), sur deux lignes au plus.
            $suite = @()
            for ($j = $i + 1; $j -lt $l.Count -and $l[$j] -notmatch '^Error:' -and $suite.Count -lt 3; $j++) { $suite += $l[$j] }
            $garde += ($l[$i] + " " + ($suite -join " ")).Trim()
        }
    }
    if (-not $garde.Count) { $garde = $l | Select-Object -Last 3 }
    return (@($garde | Select-Object -Unique | Select-Object -First $Max) -join " | ")
}

if ($AvantMonter) {
    if (@($Atelier).Count -ne 1 -or $Atelier[0] -ne 11) { throw "-AvantMonter ne vaut que pour l'atelier 11 : -Atelier 11 -AvantMonter" }
    $Couche = "infra/00-cloud-hetzner"
    $pieces = @("$Couche/reseau.tf", "$Couche/calcul.tf", "$Couche/user_data.sh.tftpl")
    Titre "Atelier 11 - Avant de monter : la couche est-elle prête ? (rien n'est créé chez Hetzner)"

    # 1. Le terminal : les trois variables que cloud.ps1 et OpenTofu lisent.
    Controle "Le token de l'équipe est dans ce terminal (HCLOUD_TOKEN, 64 caractères)" {
        $env:HCLOUD_TOKEN -and $env:HCLOUD_TOKEN.Length -eq 64
    } "les deux lignes de la fiche 11, partie 1 : `$s = Read-Host -AsSecureString, puis `$env:HCLOUD_TOKEN = ... ; un token se colle en entier, sans espace"
    Controle "L'identifiant de l'équipe (TF_VAR_eleve = velocite-equipeN)" {
        $env:TF_VAR_eleve -cmatch '^velocite-(equipe[1-9][0-9]?|prof)$'
    } "`$env:TF_VAR_eleve = `"velocite-equipe3`" (votre numéro, celui du message Moodle), en minuscules"
    Controle "La phrase du state (TF_VAR_phrase_etat, 16 caractères au moins)" {
        $env:TF_VAR_phrase_etat -and $env:TF_VAR_phrase_etat.Length -ge 16
    } "`$env:TF_VAR_phrase_etat = Read-Host `"Phrase du state`" : la même toute l'équipe, notée hors du dépôt"

    # 2. Les trois pièces : plus aucune marque à compléter.
    $restes = @()
    foreach ($f in $pieces) {
        $n = 0
        foreach ($ligne in ((Texte $f) -split "`r?`n")) {
            $n++
            if ($ligne -match 'A FAIRE') { $restes += "$(Split-Path -Leaf $f):$n" }
        }
    }
    Controle "Les trois pièces sont complètes : plus aucune marque A FAIRE" {
        $restes.Count -eq 0 -and (Texte "$Couche/reseau.tf") -and (Texte "$Couche/calcul.tf")
    } ("à compléter : " + ($restes -join ", ") + " ; le commentaire au-dessus de chaque ligne dit quoi mettre")

    # 3. La forme, puis la syntaxe.
    if (-not (Test-Path (Join-Path $Racine "$Couche/.terraform"))) {
        Lancer-Tout tofu @("-chdir=$Couche", "init", "-input=false", "-no-color") | Out-Null
    }
    $fmt = Lancer-Tout tofu @("-chdir=$Couche", "fmt", "-check", "-no-color")
    Controle "tofu fmt : la mise en forme est la bonne" {
        $fmt.Code -eq 0
    } ("à remettre en forme : " + (($fmt.Texte -split "`r?`n" | Where-Object { $_ }) -join ", ") + " ; tofu -chdir=$Couche fmt")
    $val = Lancer-Tout tofu @("-chdir=$Couche", "validate", "-no-color")
    Controle "tofu validate : la syntaxe et les noms sont justes" {
        $val.Code -eq 0
    } ((Extraire-Erreurs $val.Texte) + " ; le message donne le fichier et la ligne")

    # 4. Le script de premier démarrage : il est rendu dans la machine, le
    #    plan n'en montre qu'une empreinte. On le lit donc ici.
    $ud = ((Texte "$Couche/user_data.sh.tftpl") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Controle "user_data.sh.tftpl : k3s à la version d'OpenTofu, certificat pour l'adresse publique, fichier témoin" {
        ($ud -match 'get\.k3s\.io') -and ($ud -match 'INSTALL_K3S_VERSION="\$\{version_k3s\}"') -and
        ($ud -match '--tls-san\s+"\$IP"') -and ($ud -match '(?m)^\s*touch\s+/var/lib/velocite-pret\s*$')
    } "user_data.sh.tftpl, pièce 3 : la version que passe OpenTofu (3.a), l'adresse lue à l'étape 2 (3.b), le fichier témoin qu'attend cloud.ps1 (3.c)"

    # 5. Le token n'est nulle part dans le dépôt, ni dans son historique.
    Controle "Le token n'est écrit dans aucun fichier du dépôt, ni dans son historique" {
        if (-not $env:HCLOUD_TOKEN) { return $false }
        $fichiers = Lancer git @("grep", "-I", "-l", "--untracked", "-F", "-e", $env:HCLOUD_TOKEN)
        $histoire = Lancer git @("log", "--all", "--oneline", "-S", $env:HCLOUD_TOKEN)
        (-not $fichiers.Texte) -and (-not $histoire.Texte)
    } "effacez-le du fichier ; s'il a été commité ou poussé, prévenez l'intervenant : il le révoque et vous en donne un autre"

    # 6. Le plan, seulement si tout le reste est OK : il dit exactement ce que
    #    monter créerait. Rien n'est créé.
    if ($script:ko) {
        $script:total++
        $script:ko++
        Write-Host "KO  tofu plan : pas lancé" -ForegroundColor Red
        Write-Host "      -> corrigez d'abord les KO ci-dessus, puis relancez ce script" -ForegroundColor DarkYellow
    } else {
        $ip = $MonIp
        if (-not $ip) {
            try { $ip = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 15).Trim() } catch { $ip = "" }
        }
        $plan = Join-Path ([System.IO.Path]::GetTempPath()) ("velocite-avant-monter-{0}.plan" -f $PID)
        $p = Lancer-Tout tofu @("-chdir=$Couche", "plan", "-input=false", "-no-color", "-lock=false", "-var=mon_ip=$ip/32", "-out=$plan")
        $json = $null
        if ($p.Code -eq 0 -and (Test-Path $plan)) {
            $s = Lancer tofu @("-chdir=$Couche", "show", "-json", $plan)
            if ($s.Code -eq 0) { $json = $s.Texte | ConvertFrom-Json }
        }
        if (Test-Path $plan) { Remove-Item $plan -Force }
        $ligne = @($p.Texte -split "`r?`n" | Where-Object { $_ -match '^(Plan:|No changes)' }) | Select-Object -First 1
        $actions = @()
        if ($json) { $actions = @($json.resource_changes | ForEach-Object { @($_.change.actions) -join "," }) }
        $ajouts = @($actions | Where-Object { $_ -eq "create" }).Count
        $autres = @($actions | Where-Object { $_ -ne "create" -and $_ -ne "no-op" -and $_ -ne "read" }).Count
        $deja = @($actions | Where-Object { $_ -eq "no-op" }).Count
        Controle "tofu plan : 5 ressources à créer (clé TLS, clé SSH, fichier de clé, pare-feu, serveur), rien à modifier ni à détruire" {
            $json -and $autres -eq 0 -and (($ajouts -eq 5) -or ($deja -gt 0 -and $ajouts + $deja -eq 5))
        } $(if ($p.Code -ne 0) { (Extraire-Erreurs $p.Texte) + " ; adresse lue : $ip/32" } else { "le plan dit : $ligne" })

        # Le détail du plan, seulement s'il a abouti : sinon, le KO du plan
        # dit déjà pourquoi.
        if (-not $json) {
            Write-Host "      (le détail du pare-feu et du serveur se lira quand le plan aboutira)" -ForegroundColor DarkYellow
        } else {
        $res = @($json.planned_values.root_module.resources)
        $fw = @($res | Where-Object { $_.address -eq "hcloud_firewall.k3s" } | Select-Object -First 1)
        $srv = @($res | Where-Object { $_.address -eq "hcloud_server.k3s" } | Select-Object -First 1)
        Controle "Le pare-feu : 22, 6443 et 30443 en entrée, chacun depuis votre seule adresse en /32" {
            if (-not $fw) { return $false }
            $regles = @($fw[0].values.rule)
            $ports = @($regles | ForEach-Object { [string]$_.port } | Sort-Object)
            (($ports -join ",") -eq "22,30443,6443") -and
            (@($regles | Where-Object { $_.direction -ne "in" -or $_.protocol -ne "tcp" -or @($_.source_ips).Count -ne 1 -or [string]@($_.source_ips)[0] -ne "$ip/32" }).Count -eq 0)
        } "reseau.tf, 1.a et 1.b : les trois ports de la slide 29, et votre adresse par la variable déclarée pour elle"
        Controle "Le serveur : le nom de l'équipe, cx33, Ubuntu 24.04, un centre de données prévu" {
            if (-not $srv) { return $false }
            $v = $srv[0].values
            ($v.name -ceq $env:TF_VAR_eleve) -and ($v.server_type -eq "cx33") -and ($v.image -eq "ubuntu-24.04") -and
            (@("nbg1", "fsn1", "hel1") -contains $v.location)
        } "calcul.tf, 2.a, 2.c et 2.d : le nom, le type et le centre de données viennent des variables de variables.tf"
        $cfg = @($json.configuration.root_module.resources | Where-Object { $_.address -eq "hcloud_server.k3s" } | Select-Object -First 1)
        Controle "Le serveur porte le pare-feu, la clé SSH, et la version de k3s d'OpenTofu" {
            if (-not $cfg) { return $false }
            $e = $cfg[0].expressions
            (@($e.firewall_ids.references) -contains "hcloud_firewall.k3s.id") -and
            (@($e.ssh_keys.references) -contains "hcloud_ssh_key.k3s.id") -and
            (@($e.user_data.references) -contains "var.version_k3s")
        } "calcul.tf, 2.e, 2.f et 2.g : l'id de la clé SSH, l'id du pare-feu de reseau.tf, la variable de la version de k3s"
        }
    }

    Write-Host ""
    $couleur = if ($script:ko) { "Red" } else { "Green" }
    Write-Host ("{0} contrôles, {1} KO" -f $script:total, $script:ko) -ForegroundColor $couleur
    if ($script:ko) {
        Write-Host "Rien n'a été créé chez Hetzner. Corrigez chaque KO, puis relancez." -ForegroundColor DarkYellow
        exit 1
    }
    Write-Host "Tout est prêt : ./scripts/cloud.ps1 -Etape monter peut créer la machine." -ForegroundColor Green
    exit 0
}

$kubeOk = (Lancer kubectl @("get", "--raw", "/readyz")).Code -eq 0
if (-not $kubeOk) {
    Write-Host "Le cluster ne répond pas : tous les contrôles du cluster seront KO." -ForegroundColor DarkYellow
    Write-Host "  -> Docker Desktop démarré ? kubectl config use-context kind-velocite" -ForegroundColor DarkYellow
}

# ------------------------------------------------------------------ atelier 1
if ($Atelier -contains 1) {
    Titre "Atelier 1 - L'inventaire, le dépôt du binôme"
    Controle "docs/INVENTAIRE.md : les sections remplies (1 à 5)" {
        (Section-Remplie "docs/INVENTAIRE.md" "1." "j1") -and (Section-Remplie "docs/INVENTAIRE.md" "5." "j1")
    } "chaque section donne sa commande : la lancer, remplir le tableau"
    Controle "docs/ARCHITECTURE.md : Vue d'ensemble remplie" {
        Section-Remplie "docs/ARCHITECTURE.md" "Vue d'ensemble" "j1"
    } "le croquis de lundi, en texte"
    Controle "Aucun secret suivi par Git (git ls-files app/secrets vide)" {
        -not (Lancer git @("ls-files", "app/secrets")).Texte
    } "git rm --cached sur le fichier, puis commit ; me prévenir"
    Controle "Le remote origin (votre dépôt) et le remote cours existent" {
        ((Lancer git @("remote", "get-url", "origin")).Code -eq 0) -and ((Lancer git @("remote", "get-url", "cours")).Code -eq 0)
    } "Commandes_J1, atelier 1 suite"
}

# ------------------------------------------------------------------ atelier 2
if ($Atelier -contains 2) {
    Titre "Atelier 2 - L'image du batch et la CI"
    $df = Texte "app/services/batch/Dockerfile"
    Controle "app/services/batch/Dockerfile existe" { [bool]$df } "le Dockerfile de lundi ; sinon correction_J4.zip"
    Controle "Image de base épinglée par digest (@sha256:)" { $df -match '(?m)^\s*(ARG|FROM)\b.*@sha256:[0-9a-f]{64}' } "FROM image:tag@sha256:..."
    Controle "Construction en plusieurs étapes (multi-stage)" { ([regex]::Matches($df, '(?m)^\s*FROM\s')).Count -ge 2 } "une étape de construction, une d'exécution"
    Controle "L'image ne tourne pas en root (USER)" { $df -match '(?m)^\s*USER\s+(?!root|0\b)\S+' } "USER 10001:10001"
    $img = Lancer docker @("image", "inspect", "velocite/batch:1.0.0", "--format", "{{.Config.User}}|{{.Size}}")
    Controle "Image velocite/batch:1.0.0 construite, utilisateur 10001:10001" {
        ($img.Code -eq 0) -and ($img.Texte.Split("|")[0] -eq "10001:10001")
    } "./scripts/charger-images.ps1"
    Controle "Image du batch sous 300 Mo" {
        ($img.Code -eq 0) -and ([int64]$img.Texte.Split("|")[1] -lt 300MB)
    } "multi-stage : pip et les outils de construction restent dans la première étape"
    $ci = Texte ".github/workflows/ci.yml"
    Controle "CI : job images avec construction, Trivy bloquant et contrôle de l'utilisateur" {
        ($ci -match 'docker build') -and ($ci -match 'trivy') -and ($ci -match '--ignore-unfixed') -and
        ($ci -match '--exit-code 1') -and ($ci -match 'Config\.User')
    } ".github/workflows/ci.yml, les trois steps du A FAIRE"
}

# ------------------------------------------------------------------ atelier 3
if ($Atelier -contains 3) {
    Titre "Atelier 3 - Le cluster et les outils"
    Controle "infra/00-cluster : resource kind_cluster et ses trois sorties" {
        ((Texte "infra/00-cluster/main.tf") -match 'resource\s+"kind_cluster"') -and
        ((Texte "infra/00-cluster/outputs.tf") -match 'output\s+"contexte_kubectl"') -and
        ((Texte "infra/00-cluster/outputs.tf") -match 'output\s+"endpoint"') -and
        ((Texte "infra/00-cluster/outputs.tf") -match 'output\s+"kubeconfig_path"')
    } "atelier 3, A FAIRE 1 à 5"
    Controle "kubectl regarde le cluster kind-velocite, qui répond" {
        ((Lancer kubectl @("config", "current-context")).Texte -eq "kind-velocite") -and $kubeOk
    } "kubectl config use-context kind-velocite ; Docker Desktop démarré ?"
    Controle "Tous les nodes Ready" {
        $n = Kube-Json @("get", "nodes")
        $n -and (@($n.items).Count -ge 1) -and (@($n.items | Where-Object {
            -not (@($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count)
        }).Count -eq 0)
    } "kubectl get nodes ; kubectl describe node"
    Controle "Argo, Prometheus et Grafana prêts (namespaces argo, observabilite)" {
        (Deploiement-Pret "argo" "argo-workflows-workflow-controller") -and
        (Deploiement-Pret "observabilite" "prometheus-server") -and (Deploiement-Pret "observabilite" "grafana")
    } "kubectl get pods -A ; tofu -chdir=infra/10-outils apply"
    Controle "metrics-server mesure (kubectl top nodes)" { (Lancer kubectl @("top", "nodes")).Code -eq 0 } "attendre une minute après le démarrage"
    Controle "docs/DEPLOIEMENT.md : sections 2 à 4 remplies" {
        (Section-Remplie "docs/DEPLOIEMENT.md" "2." "j2") -and (Section-Remplie "docs/DEPLOIEMENT.md" "3." "j2") -and
        (Section-Remplie "docs/DEPLOIEMENT.md" "4." "j2")
    } "ce que vous avez tapé, ce qu'on doit voir"
}

# ------------------------------------------------------------------ atelier 4
if ($Atelier -contains 4) {
    Titre "Atelier 4 - L'environnement dev"
    Controle "Plus aucune valeur A_REMPLIR dans infra/20-env/modules" {
        -not ((Texte "infra/20-env/modules/espace/main.tf") + (Texte "infra/20-env/modules/secrets/main.tf") -match '__A_REMPLIR__')
    } "le commentaire au-dessus de chaque valeur"
    $ns = Kube-Json @("get", "namespace", "velocite-dev")
    Controle "Namespace velocite-dev en Pod Security restricted" {
        (Propriete $ns "metadata.labels").'pod-security.kubernetes.io/enforce' -eq "restricted"
    } "tofu apply de infra/20-env, workspace dev"
    Controle "Quota plafonds et LimitRange defauts" {
        (Kube-Json @("-n", "velocite-dev", "get", "resourcequota", "plafonds")) -and
        (Kube-Json @("-n", "velocite-dev", "get", "limitrange", "defauts"))
    } "modules/espace : kubernetes_resource_quota_v1, kubernetes_limit_range_v1"
    Controle "NetworkPolicy tout-refuser et autoriser-dns" {
        (Kube-Json @("-n", "velocite-dev", "get", "networkpolicy", "tout-refuser")) -and
        (Kube-Json @("-n", "velocite-dev", "get", "networkpolicy", "autoriser-dns"))
    } "modules/espace : les deux règles du namespace"
    Controle "Secrets velocite-db, -app, -redis, -garage, -tls-nginx présents" {
        $s = Kube-Json @("-n", "velocite-dev", "get", "secrets")
        $noms = @($s.items | ForEach-Object { $_.metadata.name })
        @("velocite-db", "velocite-app", "velocite-redis", "velocite-garage", "velocite-tls-nginx" | Where-Object { $noms -notcontains $_ }).Count -eq 0
    } "modules/secrets ; tofu apply"
    Controle "Un pod root est refusé (essai à blanc, rien n'est créé)" {
        $avant = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $e = & kubectl -n velocite-dev run essai-verif --image=mirror.gcr.io/library/busybox:1.37 `
                --restart=Never --dry-run=server -- id 2>&1
        } finally { $ErrorActionPreference = $avant }
        $kubeOk -and ((@($e) -join " ") -match "violates PodSecurity")
    } "le label pod-security.kubernetes.io/enforce manque"
    Controle "scripts/up.ps1 : les étapes outils et environnement" {
        $u = Texte "scripts/up.ps1"
        ($u -match 'infra/10-outils') -and ($u -match 'infra/20-env')
    } "complement_J3 ; deux Invoke-Etape"
}

# ------------------------------------------------------------------ atelier 5
if ($Atelier -contains 5) {
    Titre "Atelier 5 - VéloCité dans dev"
    Controle "Les trois manifestes, listés dans la base" {
        $k = Texte "deploy/base/kustomization.yaml"
        (Test-Path "deploy/base/ingest.yaml") -and (Test-Path "deploy/base/nginx.yaml") -and (Test-Path "deploy/base/loadgen.yaml") -and
        ($k -match 'ingest\.yaml') -and ($k -match 'nginx\.yaml') -and ($k -match 'loadgen\.yaml')
    } "deploy/base/kustomization.yaml, liste resources"
    Controle "Le rendu de dev passe (kubectl kustomize)" { (Lancer kubectl @("kustomize", "deploy/overlays/dev")).Code -eq 0 } "le message nomme le fichier fautif"
    Controle "Les règles réseau ingest, loadgen, postgres et batch" {
        $r = Texte "deploy/base/reseau.yaml"
        @("ingest", "loadgen", "postgres", "batch" | Where-Object { $r -notmatch "(?m)^\s+name:\s+$_\s*$" }).Count -eq 0
    } "deploy/base/reseau.yaml, fin de fichier"
    Controle "Pas de liste vide (egress: [] ou ingress: []) dans reseau.yaml" {
        (Texte "deploy/base/reseau.yaml") -notmatch '(?m)^\s+(egress|ingress):\s*\[\]'
    } "policyTypes suffit ; une liste vide rend kubectl diff jamais vide"
    Controle "dev : api, ingest, nginx, loadgen, redis prêts" {
        @("api", "ingest", "nginx", "loadgen", "redis" | Where-Object { -not (Deploiement-Pret "velocite-dev" $_) }).Count -eq 0
    } "kubectl -n velocite-dev get pods ; describe, events, logs --previous"
    Controle "dev : postgres et garage prêts, initialisation terminée" {
        $j = Kube-Json @("-n", "velocite-dev", "get", "job", "initialisation")
        (Statefulset-Pret "velocite-dev" "postgres") -and (Statefulset-Pret "velocite-dev" "garage") -and ((Propriete $j "status.succeeded") -ge 1)
    } "kubectl -n velocite-dev get sts,job"
    Controle "https://localhost:8443 répond, certificat vérifié" { Repond 8443 } "le Service nginx en NodePort 30443 (overlay dev)"
    Controle "kubectl diff -k deploy/overlays/dev : vide" { Diff-Vide "dev" } "le dépôt et le cluster diffèrent : apply, ou réparer le dépôt"
    Controle "docs : DEPLOIEMENT section 5, PARAMETRES Les applications" {
        (Section-Remplie "docs/DEPLOIEMENT.md" "5." "j2") -and (Section-Remplie "docs/PARAMETRES.md" "Les applications" "j2")
    } "fiche de l'atelier 5, Ce qui est attendu"
}

# ------------------------------------------------------------------ atelier 6
if ($Atelier -contains 6) {
    Titre "Atelier 6 - La prod, puis une nouvelle version"
    Controle "Namespace velocite-prod en Pod Security restricted" {
        (Propriete (Kube-Json @("get", "namespace", "velocite-prod")) "metadata.labels").'pod-security.kubernetes.io/enforce' -eq "restricted"
    } "tofu, workspace prod, envs/prod.tfvars"
    Controle "prod : api, ingest, nginx, loadgen, redis prêts ; deux ingest, deux nginx" {
        (@("api", "ingest", "nginx", "loadgen", "redis" | Where-Object { -not (Deploiement-Pret "velocite-prod" $_) }).Count -eq 0) -and
        ((Propriete (Kube-Json @("-n", "velocite-prod", "get", "deployment", "ingest")) "spec.replicas") -eq 2) -and
        ((Propriete (Kube-Json @("-n", "velocite-prod", "get", "deployment", "nginx")) "spec.replicas") -eq 2)
    } "kubectl apply -k deploy/overlays/prod"
    Controle "prod : autoscaler de l'API (2 à 4), trois budgets d'interruption" {
        $h = Kube-Json @("-n", "velocite-prod", "get", "hpa", "api")
        $p = Kube-Json @("-n", "velocite-prod", "get", "pdb")
        ((Propriete $h "spec.minReplicas") -eq 2) -and ((Propriete $h "spec.maxReplicas") -eq 4) -and (@($p.items).Count -ge 3)
    } "deploy/overlays/prod/disponibilite.yaml"
    Controle "https://localhost:9443 répond, certificat vérifié" { Repond 9443 } "le Service nginx en NodePort 30444 (overlay prod)"
    Controle "L'API 2.2.0 en service en dev et en prod" {
        @("velocite-dev", "velocite-prod" | Where-Object {
            (Propriete (Kube-Json @("-n", $_, "get", "deployment", "api")) "spec.template.spec.containers")[0].image -notmatch ':2\.2\.0$'
        }).Count -eq 0
    } "newTag: 2.2.0 dans les deux overlays, dev d'abord"
    Controle "La réparation dans la base : TRIPS_CACHE_TTL dans deploy/base/api.yaml" {
        (Texte "deploy/base/api.yaml") -match 'TRIPS_CACHE_TTL'
    } "app/CHANGELOG.md, version 2.2.0"
    Controle "kubectl diff vide en dev et en prod" { (Diff-Vide "dev") -and (Diff-Vide "prod") } "une correction faite à la main ? la remettre dans le dépôt"
    Controle "docs : RUNBOOK Retour arrière ; ARCHITECTURE Les deux environnements, Ce qui garde la plateforme durcie" {
        (Section-Remplie "docs/RUNBOOK.md" "Retour arrière" "j3") -and (Section-Remplie "docs/ARCHITECTURE.md" "Les deux environnements" "j1") -and
        (Section-Remplie "docs/ARCHITECTURE.md" "Ce qui garde la plateforme durcie" "j1")
    } "fiche de l'atelier 6"
}

# ------------------------------------------------------------------ atelier 7
if ($Atelier -contains 7) {
    Titre "Atelier 7 - Le bilan quotidien dans Argo"
    Controle "argo lint du modèle (sans cluster)" {
        (Lancer argo @("lint", "--offline", "workflows/bilan-quotidien.yaml")).Code -eq 0
    } "argo lint --offline workflows/bilan-quotidien.yaml : le message dit la ligne"
    $wf = Texte "workflows/bilan-quotidien.yaml"
    Controle "1 - Un DAG de quatre tâches, chacune après la précédente" {
        ($wf -match '(?m)^\s+dag:\s*$') -and ([regex]::Matches($wf, '(?m)^\s+(depends|dependencies):').Count -ge 3) -and
        (@("extract", "check", "aggregate", "publish" | Where-Object { $wf -notmatch "value:\s*$_\b" }).Count -eq 0)
    } "template bilan : dag, tasks, depends"
    Controle "2 - Relance sur le seul code 75, délai croissant" {
        ($wf -match '(?s)retryStrategy:.*?expression:[^\n]*\b75\b') -and ($wf -match '(?s)backoff:.*?factor:')
    } "retryStrategy : expression, backoff (duration, factor)"
    Controle "3 - Un mutex : jamais deux bilans à la fois" { $wf -match '(?m)^\s+mutex(es)?:' } "spec.synchronization.mutexes"
    Controle "4 - L'issue toujours publiée : onExit signaler" { $wf -match '(?m)^\s+onExit:\s*["'']?signaler["'']?\s*(#.*)?$' } "spec.onExit"
    Controle "5 - Une durée maximale" { $wf -match '(?m)^\s+activeDeadlineSeconds:\s*\d+' } "spec.activeDeadlineSeconds"
    Controle "Le modèle du cluster est celui du dépôt (kubectl diff vide)" {
        $kubeOk -and (Lancer kubectl @("-n", "velocite-dev", "diff", "-f", "workflows/bilan-quotidien.yaml")).Code -eq 0
    } "kubectl -n velocite-dev apply -f workflows"
    Controle 'BATCH_FAIL_RATE remis à "0" dans le dépôt' {
        (Texte "workflows/bilan-quotidien.yaml") -match '(?s)BATCH_FAIL_RATE["'']?\s*,?\s*\r?\n?\s*value:\s*["'']?0(\.0)?["'']?\s*[},\r\n]'
    } "sinon le bilan échouera certaines nuits"
    Controle "Un bilan du 12 mars Succeeded" {
        $w = Kube-Json @("-n", "velocite-dev", "get", "workflows")
        @($w.items | Where-Object {
            ((Propriete $_ "status.phase") -eq "Succeeded") -and
            (@(Propriete $_ "spec.arguments.parameters") | Where-Object { $_ -and (Propriete $_ "name") -eq "date" -and (Propriete $_ "value") -eq "2026-03-12" })
        }).Count -ge 1
    } "argo -n velocite-dev submit --from workflowtemplate/bilan-quotidien -p date=2026-03-12 (un bilan réussi reste 24 h)"
    Controle "Une relance vue : une étape rejouée après un code 75" {
        $w = Kube-Json @("-n", "velocite-dev", "get", "workflows")
        @($w.items | ForEach-Object { $n = Propriete $_ "status.nodes"; if ($n) { $n.PSObject.Properties.Value } } |
            Where-Object { $_ -and ((Propriete $_ "displayName") -match '\(1\)$') }).Count -ge 1
    } 'BATCH_FAIL_RATE à "0.3", relancer le bilan, puis argo get : une étape (1)' 
    Controle "L'issue publiée dans la Pushgateway (env dev)" {
        $m = Lancer kubectl @("get", "--raw", "/api/v1/namespaces/observabilite/services/prometheus-prometheus-pushgateway:9091/proxy/metrics")
        $m.Texte -match 'velocite_bilan_dernier_statut\{[^}]*env="dev"'
    } "onExit signaler ; règle réseau batch vers la Pushgateway (9091)"
    Controle "Des lignes pour le 12 mars dans daily_region_stats" {
        $r = Lancer kubectl @("-n", "velocite-dev", "exec", "-i", "statefulset/postgres", "--", "sh", "-c",
                              'PGPASSWORD=$(cat /run/secrets/postgres_password) psql -U postgres -d velocite -At') `
                              -Entree "SELECT count(*) FROM daily_region_stats WHERE jour = '2026-03-12';"
        ($r.Code -eq 0) -and ([int]($r.Texte.Trim()) -gt 0)
    } "./scripts/compter-bilan.ps1"
    Controle "Le calendrier : 2 h 30, Europe/Paris, Forbid" {
        $c = Kube-Json @("-n", "velocite-dev", "get", "cronworkflow", "bilan-quotidien")
        (@(Propriete $c "spec.schedules") -contains "30 2 * * *") -and ((Propriete $c "spec.timezone") -eq "Europe/Paris") -and
        ((Propriete $c "spec.concurrencyPolicy") -eq "Forbid")
    } "workflows/cron-bilan.yaml ; kubectl -n velocite-dev apply -f workflows"
    Controle "docs : RUNBOOK Reprise du bilan ; PARAMETRES Le bilan quotidien" {
        (Section-Remplie "docs/RUNBOOK.md" "Reprise du bilan" "j3") -and (Section-Remplie "docs/PARAMETRES.md" "Le bilan quotidien" "j2")
    } "fiche de l'atelier 7"
}

# ------------------------------------------------------------------ atelier 8
if ($Atelier -contains 8) {
    Titre "Atelier 8 - Les alertes, leurs tests, le tableau de bord"
    $fournies = @("VelociteSansReplicaPret", "MiseAJourBloquee", "BilanEchoue", "BilanEnRetard")
    # Les lignes de commentaire du modèle citent déjà les métriques : on les retire.
    $regles = ((Texte "observability/regles/alertes.yaml") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $noms = @([regex]::Matches($regles, '(?m)^\s*-\s*alert:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $ajoutees = @($noms | Where-Object { $fournies -notcontains $_ })
    Controle "Au moins deux alertes ajoutées ($($ajoutees -join ', '))" { $ajoutees.Count -ge 2 } "observability/regles/alertes.yaml"
    Controle "Une alerte lit le client témoin, une le compte data science" {
        ($regles -match 'velocite_client_requests_total|velocite_client_|velocite:echecs_client') -and ($regles -match 'velocite_rows_exported_total')
    } "les deux métriques de la fiche"
    # Le test de l'alerte sur objectif (atelier 9) est dans slo_test.yaml.
    $tests = (((Texte "observability/tests/alertes_test.yaml") + "`n" + (Texte "observability/tests/slo_test.yaml")) -split "`r?`n" |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Controle "Un test par alerte ajoutée" {
        ($ajoutees.Count -ge 1) -and (@($ajoutees | Where-Object { $tests -notmatch "alertname:\s*$_\b" }).Count -eq 0)
    } "observability/tests/alertes_test.yaml : alertname de chaque alerte ajoutée"
    Controle "Chaque test vérifie aussi que l'alerte ne part pas (exp_alerts: [])" {
        ($ajoutees.Count -ge 1) -and @($ajoutees | Where-Object { $tests -notmatch "alertname:\s*$_\s*,?\s*exp_alerts:\s*\[\]" -and $tests -notmatch "(?s)alertname:\s*$_\s*\r?\n\s*exp_alerts:\s*\[\]" }).Count -eq 0
    } "un cas où elle ne doit pas partir"
    Controle "promtool check rules : SUCCESS" {
        (Lancer "$PSScriptRoot/promtool.ps1" @("check", "rules", "observability/regles/alertes.yaml")).Code -eq 0
    } "./scripts/promtool.ps1 check rules observability/regles/alertes.yaml ; Docker démarré ?"
    Controle "promtool test rules : SUCCESS" {
        (Lancer "$PSScriptRoot/promtool.ps1" @("test", "rules", "observability/tests/alertes_test.yaml")).Code -eq 0
    } "./scripts/promtool.ps1 test rules observability/tests/alertes_test.yaml"
    Controle "Les règles du dépôt chargées dans Prometheus" {
        $r = Lancer kubectl @("get", "--raw", "/api/v1/namespaces/observabilite/services/prometheus-server:80/proxy/api/v1/rules")
        ($r.Code -eq 0) -and (@($noms | Where-Object { $r.Texte -notmatch "`"$_`"" }).Count -eq 0)
    } "tofu -chdir=infra/10-outils apply, puis une minute"
    Controle "Le tableau de bord du dépôt : JSON valide, un panneau sur le client témoin" {
        $j = Texte "observability/dashboards/velocite.json"
        $o = $j | ConvertFrom-Json
        (@(Propriete $o "panels").Count -ge 1) -and ($j -match 'velocite_client')
    } "Inspect, Panel JSON : copié dans la liste panels de observability/dashboards/velocite.json"
    Controle "RUNBOOK : la section de chaque alerte ajoutée (son ancre runbook)" {
        $rb = Texte "docs/RUNBOOK.md"
        $ancres = @([regex]::Matches($regles, 'runbook:\s*\S*#([A-Za-z0-9_-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        ($ajoutees.Count -ge 1) -and (@($ancres | Where-Object { $rb -notmatch "id=`"$_`"" }).Count -eq 0)
    } "docs/RUNBOOK.md : <a id=...> et sa section, pour chaque ancre citée par une alerte"
    Controle "API de dev remise : prête, et diff vide" { (Deploiement-Pret "velocite-dev" "api") -and (Diff-Vide "dev") } "kubectl -n velocite-dev scale deployment/api --replicas=1"
    Controle "docs : ARCHITECTURE La supervision ; PARAMETRES Les alertes ; RUNBOOK Service indisponible" {
        (Section-Remplie "docs/ARCHITECTURE.md" "La supervision" "j1") -and (Section-Remplie "docs/PARAMETRES.md" "Les alertes" "j2") -and
        (Section-Remplie "docs/RUNBOOK.md" "Service indisponible" "j3")
    } "fiche de l'atelier 8"
}


# ------------------------------------------------------------------ atelier 9
# Les alertes sur objectif : deux règles d'enregistrement (la part d'échecs
# du client témoin sur 5 min et sur 1 h), l'alerte à deux fenêtres, son test.
function Sans-Commentaires {
    param([string]$Fichier)
    # Sans l'aide (<# ... #>) ni les lignes de commentaire, qui citent déjà les
    # commandes attendues.
    $sans = [regex]::Replace((Texte $Fichier), '(?s)<#.*?#>', '')
    return ($sans -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}

if ($Atelier -contains 9) {
    Titre "Atelier 9 - Les alertes sur objectif (SLO)"
    $enr = Sans-Commentaires "observability/regles/enregistrement.yaml"
    $al = Sans-Commentaires "observability/regles/alertes.yaml"
    $slo = Texte "observability/tests/slo_test.yaml"
    Controle "enregistrement.yaml : velocite:echecs_client:ratio_rate5m et ratio_rate1h" {
        ($enr -match 'record:\s*velocite:echecs_client:ratio_rate5m') -and ($enr -match 'record:\s*velocite:echecs_client:ratio_rate1h') -and
        ($enr -match '\[5m\]') -and ($enr -match '\[1h\]') -and ($enr -match 'velocite_client_requests_total')
    } "observability/regles/enregistrement.yaml : les deux noms exacts, par namespace et par route"
    Controle "alertes.yaml : BudgetErreurConsommeVite, les deux fenêtres au-dessus de 14,4 %" {
        ($al -match 'alert:\s*BudgetErreurConsommeVite') -and ($al -match 'ratio_rate1h\s*>\s*(14\.4|0\.144)') -and
        ($al -match 'ratio_rate5m\s*>\s*(14\.4|0\.144)') -and ($al -match '\band\b')
    } "expr : ratio_rate1h > 14.4 * 0.01 and ratio_rate5m > 14.4 * 0.01"
    Controle "alertes.yaml : DisponibiliteSousObjectif retirée (une seule fenêtre)" {
        $al -notmatch 'alert:\s*DisponibiliteSousObjectif'
    } "BudgetErreurConsommeVite la remplace ; retirez aussi son test de alertes_test.yaml"
    Controle "slo_test.yaml : les trois vérifications écrites (65, 72 et 76 min)" {
        ($slo -notmatch 'A FAIRE \(atelier 9\)') -and ($slo -match 'eval_time:\s*65m') -and ($slo -match 'eval_time:\s*72m') -and
        ($slo -match 'eval_time:\s*76m') -and ([regex]::Matches($slo, 'alertname:\s*BudgetErreurConsommeVite').Count -ge 3)
    } "observability/tests/slo_test.yaml : le modèle est en commentaire dans le fichier"
    Controle "promtool check rules : SUCCESS (enregistrement et alertes)" {
        (Lancer "$PSScriptRoot/promtool.ps1" @("check", "rules", "observability/regles/enregistrement.yaml", "observability/regles/alertes.yaml")).Code -eq 0
    } "./scripts/promtool.ps1 check rules observability/regles/enregistrement.yaml ; Docker démarré ?"
    Controle "promtool test rules : SUCCESS (slo_test et alertes_test)" {
        ((Lancer "$PSScriptRoot/promtool.ps1" @("test", "rules", "observability/tests/slo_test.yaml")).Code -eq 0) -and
        ((Lancer "$PSScriptRoot/promtool.ps1" @("test", "rules", "observability/tests/alertes_test.yaml")).Code -eq 0)
    } "./scripts/promtool.ps1 test rules observability/tests/slo_test.yaml : FAILED dit l'instant (time), l'attendu (exp) et l'obtenu (got)"
    Controle "Les règles chargées dans Prometheus (l'alerte et les deux enregistrements)" {
        $r = Lancer kubectl @("get", "--raw", "/api/v1/namespaces/observabilite/services/prometheus-server:80/proxy/api/v1/rules")
        ($r.Code -eq 0) -and ($r.Texte -match '"BudgetErreurConsommeVite"') -and ($r.Texte -match 'velocite:echecs_client:ratio_rate1h')
    } "tofu -chdir=infra/10-outils apply (poste léger : -var=leger=true), puis une minute"
    Controle "RUNBOOK : la section Budget d'erreur consommé vite (ancre budget-erreur)" {
        ((Texte "docs/RUNBOOK.md") -match 'id="budget-erreur"') -and (Section-Remplie "docs/RUNBOOK.md" "Budget d'erreur" "j4")
    } "docs/RUNBOOK.md : <a id=`"budget-erreur`"></a>, puis ce qu'on voit, vérifier, agir, confirmer"
    Controle "API de dev remise : prête, et diff vide" { (Deploiement-Pret "velocite-dev" "api") -and (Diff-Vide "dev") } "kubectl -n velocite-dev scale deployment/api --replicas=1"
}


# ------------------------------------------------------------------ atelier 10
# Sauvegarder, détruire, restaurer : deux scripts, une sauvegarde hors de Git
# qui contient la donnée du jour, une vraie panne après elle, la donnée du
# jour revenue par la restauration, la procédure dans le runbook.
function Sql-Dev {
    param([string]$Sql)
    $r = Lancer kubectl @("-n", "velocite-dev", "exec", "-i", "statefulset/postgres", "--", "sh", "-c",
                          'PGPASSWORD=$(cat /run/secrets/postgres_password) psql -U postgres -d velocite -At -q') `
                          -Entree $Sql
    if ($r.Code -ne 0) { return $null }
    return $r.Texte.Trim()
}

if ($Atelier -contains 10) {
    Titre "Atelier 10 - Sauvegarder, détruire, restaurer"
    $sv = Sans-Commentaires "scripts/sauvegarder.ps1"
    $rs = Sans-Commentaires "scripts/restaurer.ps1"
    # Les sauvegardes qui contiennent la donnée du jour.
    $avecDuJour = @(Get-ChildItem -Path (Join-Path $Racine "sauvegardes") -Filter "*.sql" -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 -and (Select-String -Path $_.FullName -SimpleMatch $DuJourEmail -Quiet) } |
        Sort-Object LastWriteTimeUtc)
    # La date de naissance du disque actuel de la base.
    $pvc = Lancer kubectl @("-n", "velocite-dev", "get", "pvc", "donnees-postgres-0", "-o", "jsonpath={.metadata.creationTimestamp}")
    $disque = $null
    if ($pvc.Code -eq 0 -and $pvc.Texte) {
        $disque = [DateTimeOffset]::Parse($pvc.Texte.Trim(), [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
    }

    Controle "sauvegarder.ps1 et restaurer.ps1 : plus aucun A FAIRE" {
        $sv -and $rs -and ((Texte "scripts/sauvegarder.ps1") -notmatch 'A FAIRE') -and ((Texte "scripts/restaurer.ps1") -notmatch 'A FAIRE')
    } "scripts/sauvegarder.ps1, scripts/restaurer.ps1 : chaque A FAIRE devient une commande"
    Controle "sauvegarder.ps1 : pg_dump dans le pod, puis kubectl cp vers le poste" {
        ($sv -match 'pg_dump') -and ($sv -match '--clean') -and ($sv -match 'kubectl\s+cp')
    } "pg_dump --clean --if-exists -f /tmp/sauvegarde.sql, puis kubectl cp vers sauvegardes/"
    Controle "restaurer.ps1 : kubectl cp vers le pod, puis psql -f, arrêt à la première erreur" {
        ($rs -match 'kubectl\s+cp') -and ($rs -match 'psql') -and ($rs -match 'ON_ERROR_STOP') -and ($rs -match '\s-f\s')
    } "kubectl cp vers /tmp du pod, puis psql -v ON_ERROR_STOP=1 -f"
    Controle "sauvegardes/ ignoré par Git, aucune sauvegarde suivie" {
        ((Lancer git @("check-ignore", "-q", "sauvegardes/essai.sql")).Code -eq 0) -and -not (Lancer git @("ls-files", "sauvegardes")).Texte
    } ".gitignore : sauvegardes/ ; git rm --cached sur le fichier suivi : il contient des données personnelles"
    Controle "Une sauvegarde de sauvegardes/ contient la donnée du jour" {
        $avecDuJour.Count -ge 1
    } "./scripts/donnees-du-jour.ps1 d'abord, puis ./scripts/sauvegarder.ps1"
    Controle "Une vraie panne après la sauvegarde : le disque de la base est plus récent qu'elle" {
        $disque -and @($avecDuJour | Where-Object {
            [DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeSeconds() -lt $disque }).Count -ge 1
    } "./scripts/panne.ps1, puis kubectl apply -k deploy/overlays/dev"
    Controle ("La donnée du jour est revenue : {0} trajets, empreinte {1}" -f $DuJourTrajets, $DuJourEmpreinte) {
        (Sql-Dev $DuJourMesure) -eq ("{0} {1}" -f $DuJourTrajets, $DuJourEmpreinte)
    } "./scripts/restaurer.ps1, puis ./scripts/donnees-du-jour.ps1 -Verifier"
    Controle "Elle vient de la sauvegarde : le client existait avant le disque actuel" {
        $creation = Sql-Dev $DuJourCreation
        $disque -and $creation -and ([long]$creation -lt $disque)
    } "donnees-du-jour.ps1 relancé après la panne recrée le client : restaurez la sauvegarde"
    Controle "RUNBOOK : la section Restauration des données, avec l'empreinte notée" {
        $rb = Texte "docs/RUNBOOK.md"
        ($rb -match 'id="restauration"') -and ($rb -match $DuJourEmpreinte) -and (Section-Remplie "docs/RUNBOOK.md" "Restauration" "j4")
    } "docs/RUNBOOK.md : quand, les commandes, le nombre et l'empreinte attendus, le RPO et le RTO mesurés"
}


# ------------------------------------------------------------------ atelier 11
if ($Atelier -contains 11) {
    Titre "Atelier 11 - Le même dépôt chez Hetzner, la couche écrite par vous (hors grille)"
    Controle "Les trois pièces sont complètes : plus aucune marque A FAIRE" {
        $t = (Texte "infra/00-cloud-hetzner/reseau.tf") + (Texte "infra/00-cloud-hetzner/calcul.tf") + (Texte "infra/00-cloud-hetzner/user_data.sh.tftpl")
        $t -and ($t -notmatch 'A FAIRE')
    } "./scripts/verifier.ps1 -Atelier 11 -AvantMonter : il donne chaque ligne à compléter"
    # Les lignes de commentaire du modèle citent déjà les ports : on les retire.
    # Sans les commentaires ni les messages des garde-fous, qui citent déjà
    # les ports et 0.0.0.0/0.
    $reseau = ((Texte "infra/00-cloud-hetzner/reseau.tf") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*(error_message|condition)\s*=' }) -join "`n"
    Controle "reseau.tf : hcloud_firewall k3s, ports 22, 6443, 30443" {
        ($reseau -match 'resource\s+"hcloud_firewall"\s+"k3s"') -and
        (@("22", "6443", "30443" | Where-Object { ($reseau -notmatch "[`"']$_[`"']") -and ($reseau -notmatch "port\s*=\s*$_\b") }).Count -eq 0)
    } "infra/00-cloud-hetzner/reseau.tf : le A FAIRE, noms exacts"
    Controle "reseau.tf : ouvert à votre seule adresse (var.mon_ip), jamais à 0.0.0.0/0" {
        ($reseau -match 'var\.mon_ip') -and ($reseau -notmatch '0\.0\.0\.0/0') -and ($reseau -notmatch '::/0')
    } "source_ips = [var.mon_ip] sur chaque règle"
    $calcul = ((Texte "infra/00-cloud-hetzner/calcul.tf") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Controle "calcul.tf : hcloud_server.k3s, avec le pare-feu et le script de démarrage" {
        ($calcul -match 'resource\s+"hcloud_server"\s+"k3s"') -and ($calcul -match 'firewall_ids\s*=\s*\[\s*hcloud_firewall\.k3s\.id\s*\]') -and
        ($calcul -match 'templatefile\(') -and ($calcul -match 'user_data\.sh\.tftpl') -and ($calcul -match 'ubuntu-24\.04')
    } "infra/00-cloud-hetzner/calcul.tf : le A FAIRE, noms exacts"
    $ud = ((Texte "infra/00-cloud-hetzner/user_data.sh.tftpl") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Controle "user_data.sh.tftpl : k3s installé, version épinglée, fichier témoin" {
        ($ud -match 'get\.k3s\.io') -and ($ud -match 'INSTALL_K3S_VERSION="?\$\{version_k3s\}') -and ($ud -match '--tls-san') -and
        ($ud -match 'velocite-pret')
    } "infra/00-cloud-hetzner/user_data.sh.tftpl : le A FAIRE"
    Controle "tofu validate de infra/00-cloud-hetzner" {
        $couche = "infra/00-cloud-hetzner"
        if (-not (Test-Path (Join-Path $Racine "$couche/.terraform"))) {
            Lancer tofu @("-chdir=$couche", "init", "-backend=false", "-input=false") | Out-Null
        }
        (Lancer tofu @("-chdir=$couche", "validate")).Code -eq 0
    } "tofu -chdir=infra/00-cloud-hetzner validate : le message dit la ligne"
    Controle "Ni clé, ni state, ni token Hetzner suivis par Git" {
        $suivis = (Lancer git @("ls-files", "infra/00-cloud-hetzner")).Texte -split "`n"
        $fuite = @($suivis | Where-Object { $_ -match '/\.cles/|/\.env-cloud/|tfstate' })
        # Un token Hetzner : 64 lettres et chiffres, majuscules comprises. Les
        # empreintes du fichier de verrou sont en hexadécimal minuscule.
        $g = Lancer git @("grep", "-I", "-h", "-o", "-E", "[A-Za-z0-9]{64,}", "--", ".", ":!*.lock.hcl")
        $tokens = @($g.Texte -split "`n" | Where-Object { $_.Length -eq 64 -and $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '\d' })
        ($fuite.Count -eq 0) -and ($tokens.Count -eq 0)
    } "git rm --cached sur le fichier fautif ; un token poussé : prévenez l'intervenant, qui le révoque"
    Controle "La machine est détruite : plus de contexte kubectl hetzner-" {
        -not ((Lancer kubectl @("config", "get-contexts", "-o", "name")).Texte -match '(?m)^hetzner-')
    } "./scripts/cloud.ps1 -Etape detruire"
    Controle "docs/DEPLOIEMENT.md : une section Hetzner" {
        (Texte "docs/DEPLOIEMENT.md") -match '(?m)^#+\s.*Hetzner'
    } "ce que vous avez tapé, ce qu'on doit voir, ce qui diffère de kind"
}

# ------------------------------------------------------------------ atelier 12
# La préparation du 30 novembre (non annoncée le 23 octobre) : up.ps1
# complet et son contrôle, le tableau des preuves, la relecture croisée.
# tofu plan -detailed-exitcode : 0 rien à faire, 2 des changements, 1 une
# erreur. Le workspace passe par TF_WORKSPACE : le contrôle ne change pas le
# workspace sélectionné de la couche.
function Plan-Vide {
    param([string]$Couche, [string[]]$Vars, [string]$Workspace)
    if (-not $env:TF_VAR_phrase_etat) { return $false }
    $avant = $env:TF_WORKSPACE
    if ($Workspace) { $env:TF_WORKSPACE = $Workspace }
    try {
        $r = Lancer tofu (@("-chdir=$Couche", "plan", "-detailed-exitcode", "-input=false", "-lock=false") + $Vars)
    } finally {
        if ($null -eq $avant) { Remove-Item Env:\TF_WORKSPACE -ErrorAction SilentlyContinue } else { $env:TF_WORKSPACE = $avant }
    }
    return $r.Code -eq 0
}

if ($Atelier -contains 12) {
    Titre "Préparation du 30 novembre - Une commande, la preuve"
    $up = Texte "scripts/up.ps1"
    # Le code seul : sans l'aide (<# ... #>) ni les commentaires, qui citent
    # déjà les couches et les commandes attendues.
    $upCode = (([regex]::Replace($up, '(?s)<#.*?#>', '')) -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Controle "up.ps1 : plus aucun A FAIRE" {
        $up -and ($up -notmatch '(?m)^\s*#\s*A FAIRE')
    } "scripts/up.ps1 : chaque A FAIRE devient une étape (Invoke-Etape)"
    Controle "up.ps1 : outils, environnement, applications, bilan, tests de fumée" {
        ($upCode -match 'infra/10-outils') -and ($upCode -match 'infra/20-env') -and ($upCode -match 'deploy/overlays') -and
        ($upCode -match 'workflows') -and ($upCode -match 'smoke\.ps1')
    } "les étapes de docs/DEPLOIEMENT.md, dans l'ordre"
    Controle "up.ps1 -Controle : tofu plan -detailed-exitcode et kubectl diff" {
        ($upCode -match 'if\s*\(\s*\$Controle') -and ($upCode -match 'detailed-exitcode') -and ($upCode -match '\bdiff\b')
    } "si -Controle : un plan par couche (code 0), puis kubectl diff -k sur l'overlay (code 0)"
    Controle "README.md, Les preuves : au moins six lignes, chacune avec sa commande" {
        $l = Lignes-Section (Texte "README.md") "Les preuves"
        $pleines = @($l | Where-Object { $_ -match '^\|' } | ForEach-Object {
            $c = @($_.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            if ($c.Count -ge 3 -and $c[1] -and $c[2] -and $c[0] -ne "Ce qu'on affirme") { $_ }
        })
        ((Texte "README.md") -notmatch 'A FAIRE \((atelier 9|30 novembre)\)') -and ($pleines.Count -ge 6)
    } "pour chaque affirmation : la commande et ce qu'elle doit afficher"
    Controle "docs/DEPLOIEMENT.md : Tout monter, Tout détruire" {
        (Section-Remplie "docs/DEPLOIEMENT.md" "3." "j2") -and (Section-Remplie "docs/DEPLOIEMENT.md" "6." "j2")
    } "la commande unique, ce qu'on doit voir, et le démontage"
    Controle "RELECTURE.md écrit par le binôme voisin" {
        $f = @("RELECTURE.md", "docs/RELECTURE.md") | Where-Object { Test-Path (Join-Path $Racine $_) } | Select-Object -First 1
        $f -and (@((Texte $f) -split "`r?`n" | Where-Object { $_.Trim() }).Count -ge 5)
    } "la relecture croisée du 30 novembre : le voisin l'écrit dans votre dépôt"
    if (-not $env:TF_VAR_phrase_etat) {
        Write-Host "  `$env:TF_VAR_phrase_etat absente : les trois plans seront KO." -ForegroundColor DarkYellow
    }
    # Poste léger : un seul node (nb_workers=0), pas de Loki (leger=true).
    $nodes = Kube-Json @("get", "nodes")
    [string[]]$varsCluster = @()
    if ($nodes -and @($nodes.items).Count -eq 1) { $varsCluster = @("-var=nb_workers=0") }
    [string[]]$varsOutils = @()
    if ($kubeOk -and -not (Kube-Json @("-n", "observabilite", "get", "statefulset", "loki"))) { $varsOutils = @("-var=leger=true") }
    Controle "Un second passage ne change rien : infra/00-cluster" {
        Plan-Vide "infra/00-cluster" $varsCluster
    } "tofu -chdir=infra/00-cluster plan -detailed-exitcode : code 0 attendu ; `$env:TF_VAR_phrase_etat définie ?"
    Controle "Un second passage ne change rien : infra/10-outils" {
        Plan-Vide "infra/10-outils" $varsOutils
    } "tofu -chdir=infra/10-outils plan -detailed-exitcode (poste léger : -var=leger=true)"
    Controle "Un second passage ne change rien : infra/20-env, workspace dev" {
        Plan-Vide "infra/20-env" @("-var-file=envs/dev.tfvars") "dev"
    } "tofu -chdir=infra/20-env plan -detailed-exitcode -var-file=envs/dev.tfvars, workspace dev"
    Controle "Un second passage ne change rien : deploy/overlays/dev (kubectl diff vide)" {
        Diff-Vide "dev"
    } "kubectl diff -k deploy/overlays/dev : rien ne doit s'afficher"
}

Write-Host ""
$couleur = if ($script:ko) { "Red" } else { "Green" }
Write-Host ("{0} contrôles, {1} KO" -f $script:total, $script:ko) -ForegroundColor $couleur
if ($script:ko) { exit 1 }
