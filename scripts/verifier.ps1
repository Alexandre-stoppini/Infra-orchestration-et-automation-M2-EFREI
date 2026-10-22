<#
.SYNOPSIS
  Vérifie, atelier par atelier, que ce que demande la fiche est fait et
  fonctionne. Ne modifie rien.

.DESCRIPTION
  Un contrôle par exigence de la fiche de l'atelier : un fichier écrit, une
  valeur dans le cluster, un service qui répond, un diff vide. Chaque ligne
  dit OK ou KO ; un KO dit où regarder. Le script sort en code 1 s'il y a eu
  au moins un KO.

  Aucune phrase du state n'est demandée : tout se lit dans le dépôt, dans le
  cluster (kubectl) et dans Docker.

.EXAMPLE
  .\scripts\verifier.ps1 -Atelier 7
  .\scripts\verifier.ps1 -Atelier 1,2,3,4,5,6
  pwsh ./scripts/verifier.ps1 -Atelier 8          # macOS, Linux
#>
param(
    # Texte, puis découpé : "pwsh ./scripts/verifier.ps1 -Atelier 1,2,3" depuis
    # bash passe la liste comme un seul mot.
    [Parameter(Mandatory)][string[]]$Atelier
)
. "$PSScriptRoot/commun.ps1"
[int[]]$Atelier = @(($Atelier -join ",") -split "[,\s]+" | Where-Object { $_ } | ForEach-Object { [int]$_ })
if (@($Atelier | Where-Object { $_ -lt 1 -or $_ -gt 8 }).Count) { throw "Ateliers de 1 à 8 : -Atelier 7, ou -Atelier 1,2,3" }
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
        ($regles -match 'velocite_client_requests_total|velocite_client_') -and ($regles -match 'velocite_rows_exported_total')
    } "les deux métriques de la fiche"
    $tests = ((Texte "observability/tests/alertes_test.yaml") -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
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

Write-Host ""
$couleur = if ($script:ko) { "Red" } else { "Green" }
Write-Host ("{0} contrôles, {1} KO" -f $script:total, $script:ko) -ForegroundColor $couleur
if ($script:ko) { exit 1 }
