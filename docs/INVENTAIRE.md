# Inventaire de la configuration de VéloCité v2

A FAIRE (atelier 1, en solo). Chaque section pose une question et donne la
commande qui y répond. Votre travail : lancer la commande, lire la sortie,
remplir le tableau, répondre à la question. Une ligne dont vous n'êtes pas
sûr va en section 6, Questions ouvertes : un doute écrit vaut mieux qu'une
ligne inventée.

Toutes les commandes se lancent depuis le dossier `app`, VéloCité démarrée.
Sous Windows, dans PowerShell ; sous macOS et Linux, dans le Terminal (`jq`
doit être installé : `jq --version`).

Avant la section 1, une seule fois par terminal (Windows) :

```powershell
$c = docker compose --profile "*" config --format json | ConvertFrom-Json
```

`--profile "*"` compte aussi les services rangés dans un profil (`batch` et
`verif`), que `docker compose up` ne lance pas.

## 1. Les services

Combien de services ? Lesquels tournent en continu, lesquels s'exécutent une
fois et s'arrêtent (des jobs) ?

```
docker compose --profile "*" config --services
docker compose ps -a --format "table {{.Service}}\t{{.Status}}"
```

`Up` : un service qui tourne. `Exited (0)` : un job qui a fini sans erreur.
Les rôles sont dans `app/README.md`, section Les services. Les ports publiés
sur le poste :

```
docker compose ps --format "table {{.Service}}\t{{.Ports}}"
```

| Service | Rôle | Service ou job ? | Ports publiés |
|---|---|---|---|
| | | | |

Question : `batch` et `verif` n'apparaissent pas dans `docker compose ps`.
Pourquoi ?

## 2. Les dépendances

Qui attend qui pour démarrer ?

Windows :

```powershell
foreach ($s in $c.services.PSObject.Properties) {
  foreach ($d in $s.Value.depends_on.PSObject.Properties) {
    "{0} attend {1} ({2})" -f $s.Name, $d.Name, $d.Value.condition } }
```

macOS et Linux :

```bash
docker compose --profile "*" config --format json | jq -r '.services | to_entries[]
  | .key as $s | (.value.depends_on // {}) | to_entries[]
  | "\($s) attend \(.key) (\(.value.condition))"'
```

Collez la sortie ici, puis répondez : dans quel ordre les services
démarrent-ils ? Les trois conditions (`service_started`, `service_healthy`,
`service_completed_successfully`) sont expliquées sur la slide 11.

## 3. La configuration qui n'est pas secrète

Quels réglages chaque service reçoit-il en clair ?

Windows :

```powershell
foreach ($s in $c.services.PSObject.Properties) {
  foreach ($e in $s.Value.environment.PSObject.Properties) {
    if ($e.Name -notlike "*_FILE") { "{0}  {1}={2}" -f $s.Name, $e.Name, $e.Value } } }
```

macOS et Linux :

```bash
docker compose --profile "*" config --format json | jq -r '.services | to_entries[]
  | .key as $s | (.value.environment // {}) | to_entries[]
  | select(.key | endswith("_FILE") | not) | "\($s)  \(.key)=\(.value)"'
```

| Paramètre | Service | Valeur locale | Change entre dev et prod ? |
|---|---|---|---|
| | | | |

## 4. Les secrets

Combien de fichiers de secrets le script a-t-il générés, et combien Compose
en déclare-t-il ?

Windows :

```powershell
(Get-ChildItem ./secrets).Count
$c.secrets.PSObject.Properties.Name.Count
```

macOS et Linux :

```bash
ls secrets | wc -l
docker compose --profile "*" config --format json | jq -r '.secrets | keys[]' | wc -l
```

Qui lit quoi :

Windows :

```powershell
foreach ($s in $c.services.PSObject.Properties) {
  "{0}: {1}" -f $s.Name, ($s.Value.secrets.source -join " ") }
```

macOS et Linux :

```bash
docker compose --profile "*" config --format json | jq -r '.services | to_entries[]
  | "\(.key): \([.value.secrets[]?.source] | join(" "))"'
```

Rangez les secrets par famille (mots de passe, adresses de connexion, tokens,
clés S3, certificats) :

| Famille | Fichiers | Lus par |
|---|---|---|
| | | |

Questions :

- Certains secrets en contiennent un autre (ouvrez `secrets/database_url_api`
  et comparez avec `secrets/pg_svc_api`). Lesquels ? Que se passe-t-il si
  l'on change l'un sans l'autre ?
- Un fichier est généré mais déclaré nulle part. Lequel, et pourquoi
  n'est-ce pas une erreur ? Pour le trouver :

Windows :

```powershell
Compare-Object (Get-ChildItem ./secrets).Name $c.secrets.PSObject.Properties.Name
```

macOS et Linux :

```bash
comm -23 <(ls secrets | sort) <(docker compose --profile "*" config --format json | jq -r '.secrets | keys[]' | sort)
```

Indice : cherchez son nom dans `services/init/init.py`.

## 5. Ce qui change d'un environnement à l'autre

À partir des sections 3 et 4 et de la slide 13 : qu'est-ce qui devra avoir une
valeur différente en dev et en prod ? Une ligne par élément.

## 6. Questions ouvertes

## 7. Ce que cet inventaire protège

Une phrase, sans aucun terme technique, pour quelqu'un qui ne fait pas
d'informatique.
