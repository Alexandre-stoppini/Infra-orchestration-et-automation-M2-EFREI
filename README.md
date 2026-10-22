# velocite-ops

Le dépôt d'exploitation de **VéloCité v2**, la plateforme de mobilité partagée
durcie au module Sécurité 1. Cette semaine, vous la rendez reproductible : un
cluster Kubernetes local, deux environnements, un bilan quotidien orchestré,
une supervision. Tout sera décrit dans ce dépôt ; rien ne se crée à la main.

**Plateforme pédagogique. Données inventées, aucun secret réel, aucun secret
dans ce dépôt.**

## Ce dépôt grandit chaque soir

Vous ne recevez que ce dont vous avez besoin le jour même. Chaque soir, le
dépôt du cours reçoit un commit et un tag avec les fichiers du lendemain :
des fichiers neufs uniquement, jamais une modification de ce que vous avez
écrit.

| Tag | Journée | Ce qui arrive |
|---|---|---|
| `j1` | lundi | `app/` (VéloCité v2), `docs/INVENTAIRE.md`, `docs/ARCHITECTURE.md`, la CI à compléter |
| `j2` | mardi | `infra/` (OpenTofu), les scripts de déploiement, `docs/DEPLOIEMENT.md`, `docs/PARAMETRES.md` |
| `j3` | mercredi | `deploy/` (Kustomize), les tests de fumée, `docs/RUNBOOK.md` |
| `j4` | jeudi | `workflows/` (Argo), les tests des alertes |
| `j5` | vendredi | `observability/tests/slo_test.yaml` (atelier 9), `scripts/sauvegarder.ps1` et `scripts/restaurer.ps1` à compléter, `scripts/donnees-du-jour.ps1` et `scripts/panne.ps1` fournis (atelier 10), `infra/00-cloud-hetzner/` à compléter (`reseau.tf`, `calcul.tf`, `user_data.sh.tftpl`), `scripts/cloud.ps1` et la vérification `verifier.ps1 -Atelier 11 -AvantMonter` (atelier 11, hors grille) |

## Récupérer l'apport du jour

Chaque matin, depuis la racine de votre dépôt (remplacez `j2` par le tag du
jour) :

```
git pull --no-rebase --no-edit cours j2
git push
```

La première commande fusionne l'apport du cours dans votre travail ; la
seconde l'envoie sur votre dépôt. La commande est la même sous Windows, macOS
et Linux.

## Démarrer VéloCité, lundi

Depuis le dossier `app`. La procédure complète et les problèmes courants
sont dans `app/README.md`.

Windows (PowerShell) :

```powershell
./scripts/init-secrets.ps1
docker compose up -d
```

macOS et Linux (Terminal) :

```bash
./scripts/init-secrets.sh
docker compose up -d
```

À partir de mardi, toute la plateforme se monte par `scripts/up.ps1`, que
vous écrivez au fil des ateliers.

## Les preuves

A FAIRE (30 novembre) : pour chaque affirmation sur la plateforme, la
commande qui la prouve. Au minimum :

| Ce qu'on affirme | Commande | Ce qu'on doit voir |
|---|---|---|
| La plateforme renaît depuis zéro en une commande | | |
| Un second passage ne change rien | | |
| Le durcissement tient sur le cluster | | |
| Une mise à jour qui casse ne coupe pas le service | | |
| Le bilan reprend sans dupliquer | | |
| Les alertes se déclenchent quand il faut | | |
