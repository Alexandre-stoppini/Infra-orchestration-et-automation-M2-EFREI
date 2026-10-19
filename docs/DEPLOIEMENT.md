# Déployer VéloCité depuis zéro

A FAIRE, commencé le mardi, complété chaque jour. Le test : un binôme qui
n'a jamais vu ce dépôt monte la plateforme en suivant ce document, sans
vous poser de question. Toutes les commandes pour PowerShell (Windows, macOS
ou Linux), depuis la racine du dépôt.

## 1. Ce qu'il faut sur le poste

Le module marche sous Windows, sous macOS (processeur Intel ou Apple) et
sous Linux (processeur Intel ou AMD). Les scripts du dépôt se lancent dans
PowerShell : Windows PowerShell 5.1, fourni avec Windows, ou PowerShell 7
(commande `pwsh`) sous macOS et Linux. Les chemins s'écrivent avec des barres obliques
(`./scripts/up.ps1`) : c'est la forme qui marche sur les deux.

| Outil | Version | Rôle |
|---|---|---|
| Docker | Windows, macOS : Docker Desktop à jour (Windows : moteur WSL 2) ; Linux : Docker Engine et le plugin Compose | construit les images, fait tourner les nodes kind |
| PowerShell | Windows : 5.1, fourni ; macOS : 7, `brew install --cask powershell` ; Linux : 7, learn.microsoft.com, "Installer PowerShell sur Linux" | les scripts |
| Git | Windows : Git pour Windows ; macOS : `xcode-select --install` ; Linux : `sudo apt install git` | versionne le dépôt ; fournit le `diff` de `kubectl diff` sous Windows |
| kind | 0.33.0 | le cluster Kubernetes local |
| OpenTofu | 1.13.1 | l'infrastructure décrite en code |
| kubectl | 1.37.1 | le client Kubernetes |
| argo | 4.1.5 | le client Argo Workflows |

Les quatre derniers s'installent d'un coup, à version fixe et hash
vérifié, depuis la racine du dépôt (sous macOS et Linux : `pwsh
./scripts/installer-outils.ps1`) :

```powershell
./scripts/installer-outils.ps1
# fermez puis rouvrez PowerShell, puis :
kind version ; tofu version ; kubectl version --client ; argo version --short
(Get-Command kubectl).Source     # doit contenir velocite-outils
```

Le script ajoute aussi une ligne à votre profil PowerShell (et, sous macOS
et Linux, à `~/.zshrc` ou `~/.bashrc`) : sans elle, le `kubectl` de Docker
Desktop, plus ancien, passerait avant le vôtre. Hors de PowerShell, la
vérification s'écrit `command -v kubectl`.

Mémoire : 8 Go alloués à Docker Desktop au minimum, 12 Go conseillés.
Réglage : Docker Desktop, Settings, Resources. Sous Linux, Docker Engine
utilise directement la mémoire du poste.

Différences entre les deux systèmes :

| | Windows | macOS et Linux |
|---|---|---|
| Dossier de travail conseillé | `C:\cours` | `~/cours` |
| Appel HTTPS en ligne de commande | `curl.exe` (dans PowerShell 5.1, `curl` désigne autre chose) | `curl` |
| Scripts refusés ("l'exécution de scripts est désactivée") | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, une fois | sans objet |
| La phrase du state, hors PowerShell | sans objet | `read -rs TF_VAR_phrase_etat; export TF_VAR_phrase_etat` |

Kubernetes ne démarre que si Docker tourne en cgroup v2. Vérification :
`docker info --format '{{.CgroupVersion}}'` doit répondre `2`. Sous
macOS, c'est toujours le cas avec un Docker Desktop à jour ; sous Linux,
avec toute distribution de moins de trois ans. Sous Windows,
s'il répond `1`, mettez d'abord Docker Desktop à jour ; si c'est toujours
`1`, créez `%USERPROFILE%\.wslconfig` avec ces deux lignes, puis
`wsl --shutdown` et relancez Docker Desktop :

```
[wsl2]
kernelCommandLine = cgroup_no_v1=all
```

`up.ps1` fait ce contrôle et s'arrête avec ce message plutôt qu'avec
une erreur de kubeadm.

## 2. La phrase de passe du state

```powershell
$env:TF_VAR_phrase_etat = Read-Host "Phrase du state"
```

## 3. Tout monter, en une commande

## 4. Les étapes, une par une

Pour chaque étape : la commande, ce qu'on doit voir, comment le vérifier.

## 5. Accéder à la plateforme

## 6. Tout détruire

## 7. Quand ça bloque

| Symptôme | Cause probable | Que faire |
|---|---|---|
| | | |
