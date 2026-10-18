#
# Frontal VéloCité v2. Image nginx officielle sans privilège : le processus
# tourne sous l'utilisateur nginx (101), écoute sur 8080 et 8443, et ne peut
# pas ouvrir les ports sous 1024. Le certificat n'est PAS dans l'image : il
# est monté au lancement depuis un secret.
#
# Les images de base viennent de mirror.gcr.io, la copie de Docker Hub tenue
# par Google : même digest sha256, donc octet pour octet la même image.
# Docker Hub limite les téléchargements sans compte à 100 par 6 heures et par
# adresse IP ; mirror.gcr.io n'a pas cette limite et sert les mêmes octets.
FROM mirror.gcr.io/nginxinc/nginx-unprivileged:1.30.5-alpine@sha256:56b8272e43a0525f67aed68d1e0794a712d10e3e45a563e118e9a77c817e6f86
ARG APP_VERSION=2.0.0
LABEL org.opencontainers.image.title="velocite-nginx" \
      org.opencontainers.image.version="${APP_VERSION}"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
EXPOSE 8080 8443
