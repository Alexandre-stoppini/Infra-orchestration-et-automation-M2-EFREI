#
# Image PostgreSQL de VéloCité v2 : l'image officielle, plus le schéma, les
# rôles, les jeux d'amorçage et le point d'entrée TLS. Le contenu de démo
# voyage avec l'image : le même référentiel naît en Compose et sur Kubernetes.
# Aucun secret n'y entre : mots de passe et certificats sont montés au
# lancement.
#
# Les images de base viennent de mirror.gcr.io, la copie de Docker Hub tenue
# par Google : même digest sha256, donc octet pour octet la même image.
# Docker Hub limite les téléchargements sans compte à 100 par 6 heures et par
# adresse IP ; mirror.gcr.io n'a pas cette limite et sert les mêmes octets.
FROM mirror.gcr.io/library/postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
ARG APP_VERSION=2.0.0
LABEL org.opencontainers.image.title="velocite-postgres" \
      org.opencontainers.image.version="${APP_VERSION}"
COPY 01-schema.sql 02-donnees.sql 03-roles.sh /docker-entrypoint-initdb.d/
COPY data/ /docker-entrypoint-initdb.d/data/
COPY pg_hba.conf /etc/velocite/pg_hba.conf
COPY tls-entrypoint.sh /usr/local/bin/tls-entrypoint.sh
# Droits explicites : les fichiers copiés depuis un poste Windows n'ont pas
# de droits Unix fiables. Lecture pour tous, exécution pour les scripts.
#
# gosu ne sert qu'à abandonner root au démarrage. L'image démarre ici
# directement sous l'utilisateur postgres (uid 70) : gosu est inutile, et
# il embarque une bibliothèque Go ancienne (25 vulnérabilités HIGH ou
# CRITICAL fixables au 12 octobre 2026). On le retire.
RUN chmod -R a+rX,go-w /docker-entrypoint-initdb.d /etc/velocite \
 && chmod 0755 /docker-entrypoint-initdb.d/03-roles.sh /usr/local/bin/tls-entrypoint.sh \
 && rm -f /usr/local/bin/gosu
USER 70:70
ENTRYPOINT ["tls-entrypoint.sh"]
CMD ["postgres"]
