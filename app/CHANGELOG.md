# Historique des versions - VéloCité Data Platform

Les versions publiées par l'équipe de développement. L'équipe d'exploitation
(vous) les déploie : lisez ce fichier avant chaque mise à jour.

## 2.2.0 - 20 octobre 2026

**Changement de configuration obligatoire.**

- Les statistiques (`/stats/regions`, `/stats/heures`) sont mises en cache
  dans Redis.
- Nouvelle variable **obligatoire** : `TRIPS_CACHE_TTL`, durée de vie du cache
  en secondes (valeur conseillée : `60`). Sans elle, l'API refuse de démarrer
  et sort avec le code 78 (erreur de configuration).

## 2.1.0 - 13 octobre 2026

- Nouvelle route `GET /stats/heures` : nombre de trajets par heure de la
  journée. Rôles autorisés : `datascientist`, `analyst`, `admin`.
- Aucun changement de configuration.

## 2.0.0 - 2 octobre 2026

Version durcie, issue du module Sécurité 1. Le détail est dans `SECURITE.md`.

- Authentification : argon2id, tokens JWT HS256 à expiration, suspension
  après cinq échecs.
- Habilitations par rôle sur chaque route ; plus aucune route
  d'administration ouverte.
- Données de paiement réduites aux quatre derniers chiffres et à un jeton.
- Un rôle PostgreSQL par service ; TLS obligatoire vers PostgreSQL.
- Redis protégé par ACL ; stockage objet MinIO remplacé par Garage.
- Images reconstruites : base pinnée par digest, dépendances
  verrouillées, utilisateur sans privilège, pip retiré.
- Métriques Prometheus sur le port 9100 de l'API et de l'ingestion ; le
  générateur d'activité compte ses appels côté client (même port).
- Logs au format `cle=valeur` sur la sortie standard uniquement.

## 1.4.2 - socle de Sécurité 1

Version volontairement vulnérable du module de septembre. Ne plus déployer.
