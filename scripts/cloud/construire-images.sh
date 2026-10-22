#!/bin/bash
# Exécuté sur la machine Hetzner par scripts/cloud.ps1 -Etape deployer : construit les
# images VéloCité et les charge dans k3s (équivalent de kind load).
set -euo pipefail
rm -rf app && tar -xzf app.tgz
b() { sudo docker build -q --build-arg "APP_VERSION=$3" -t "$1" ${4:+-f "$4"} "$2" >/dev/null && echo "    $1"; }
b velocite/postgres:2.0.0 app/db/postgres 2.0.0
b velocite/init:2.0.0 app 2.0.0 app/services/init/Dockerfile
b velocite/api:2.0.0 app/services/api 2.0.0
b velocite/api:2.1.0 app/services/api 2.1.0
b velocite/api:2.2.0 app/services/api 2.2.0
b velocite/ingest:2.0.0 app/services/ingest 2.0.0
b velocite/nginx:2.0.0 app/nginx 2.0.0
b velocite/loadgen:2.0.0 app/services/loadgen 2.0.0
b velocite/batch:1.0.0 app/services/batch 1.0.0
sudo docker save $(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep '^velocite/') | sudo k3s ctr images import - >/dev/null
echo "    images chargées dans k3s"
