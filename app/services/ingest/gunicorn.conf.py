"""Serveur WSGI de production pour le service d'ingestion.

Un seul processus, plusieurs threads : on monte en charge en ajoutant des
réplicas (Kubernetes), pas des processus dans le conteneur. Cela garde aussi
les métriques simples : un processus, un registre.
"""

import os

bind = "0.0.0.0:" + os.getenv("PORT", "8081")
workers = 1
threads = int(os.getenv("GUNICORN_THREADS", "8"))
worker_class = "gthread"
timeout = 30
graceful_timeout = 20       # SIGTERM : on finit les requêtes en cours
keepalive = 5
accesslog = None            # l'API journalise elle-même chaque requête
errorlog = "-"
loglevel = "warning"
worker_tmp_dir = "/dev/shm"  # le système de fichiers racine est en lecture seule
# Pas de socket de pilotage à chaud : on pilote par l'orchestrateur, pas
# depuis l'intérieur du conteneur.
control_socket_disable = True
# L'application est chargée dans le processus maître, avant tout fork : une
# configuration invalide arrête alors le conteneur (code 78) au lieu de faire
# relancer le worker en boucle. L'orchestrateur voit l'échec, et le dit.
preload_app = True


def post_worker_init(worker):
    from prometheus_client import start_http_server
    start_http_server(int(os.getenv("METRICS_PORT", "9100")))
