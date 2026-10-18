#
# Image des outils d'initialisation VéloCité v2 (secrets locaux, stockage,
# amorçage). Construite depuis le dossier app, pour embarquer les jeux de
# données inventés (pièces KYC factices, extrait pseudonymisé) :
#   docker build -f services/init/Dockerfile -t velocite/init:2.0.0 .

# Les images de base viennent de mirror.gcr.io, la copie de Docker Hub tenue
# par Google : même digest sha256, donc octet pour octet la même image.
# Docker Hub limite les téléchargements sans compte à 100 par 6 heures et par
# adresse IP ; mirror.gcr.io n'a pas cette limite et sert les mêmes octets.
ARG PYTHON_IMAGE=mirror.gcr.io/library/python:3.13.16-slim-trixie@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f

FROM ${PYTHON_IMAGE} AS construction
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
COPY services/init/requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --require-hashes --only-binary=:all: \
        -r /tmp/requirements.txt \
 && /opt/venv/bin/pip uninstall -y -q pip

FROM ${PYTHON_IMAGE}
ARG APP_VERSION=2.0.0
LABEL org.opencontainers.image.title="velocite-init" \
      org.opencontainers.image.version="${APP_VERSION}"
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION}
# pip ne sert plus à l'exécution : on le retire, avec les bibliothèques qu'il
# embarque (et leurs vulnérabilités). Un conteneur ne s'installe pas de paquet.
RUN python -m pip uninstall -y -q pip \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin velocite
COPY --from=construction /opt/venv /opt/venv
WORKDIR /app
COPY services/init/*.py ./
COPY datasets/ /datasets/
USER 10001:10001
ENTRYPOINT ["python", "/app/init.py"]
