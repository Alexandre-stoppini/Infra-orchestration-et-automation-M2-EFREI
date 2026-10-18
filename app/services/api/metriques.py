"""Métriques Prometheus de l'API.

Exposées sur un port séparé (METRICS_PORT, 9100 par défaut) : le frontal ne
le publie pas, seul le collecteur de métriques y accède.
"""

from prometheus_client import Counter, Gauge, Histogram

REQUETES = Counter(
    "velocite_http_requests_total", "Requêtes HTTP traitées",
    ["service", "route", "method", "code"])
DUREE = Histogram(
    "velocite_http_request_duration_seconds", "Durée de traitement",
    ["service", "route"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
CONNEXIONS = Counter(
    "velocite_logins_total", "Tentatives de connexion", ["result"])
TRAJETS = Counter(
    "velocite_trips_created_total", "Trajets créés")
LIGNES_EXPORTEES = Counter(
    "velocite_rows_exported_total", "Lignes sorties par la route d'export",
    ["role"])
# Une série étiquetée n'existe qu'à son premier événement, et rate() comme
# increase() ignorent ce premier saut : la première salve après un
# redémarrage passerait inaperçue. On crée la série à zéro dès le démarrage.
LIGNES_EXPORTEES.labels("datascientist")
REFUS = Counter(
    "velocite_access_denied_total", "Accès refusés", ["route", "reason"])
BUILD = Gauge(
    "velocite_build_info", "Version déployée", ["service", "version"])
