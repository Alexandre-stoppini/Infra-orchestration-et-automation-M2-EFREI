#!/usr/bin/env bash
# Installe les outils de la CI, à version fixe, sha256 vérifié.
#
# Pourquoi pas des actions toutes faites (setup-opentofu, setup-trivy...) :
# chaque action tierce est du code qui s'exécute avec les droits du dépôt.
# En mars 2026, les tags de trivy-action ont été réécrits pour
# pointer vers du code malveillant. Un binaire officiel dont on vérifie
# le sha256 ne peut pas changer sous nos pieds.
#
# Usage : scripts/ci/outils.sh [outil...]   (sans argument : tous)
set -euo pipefail

DEST="${OUTILS_DEST:-$HOME/.local/bin}"
mkdir -p "$DEST"
echo "$DEST" >> "${GITHUB_PATH:-/dev/null}"
export PATH="$DEST:$PATH"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

telecharger() {  # url sha256 fichier
  curl -fsSL --retry 3 -o "$TMP/$3" "$1"
  echo "$2  $TMP/$3" | sha256sum -c --quiet -
}

installer() {
  case "$1" in
    tofu)
      telecharger https://github.com/opentofu/opentofu/releases/download/v1.13.1/tofu_1.13.1_linux_amd64.tar.gz \
        378ada19d4bc70c43732004e8159be771b23b9a5afdf059e5f8a2b3fa2c70a69 tofu.tgz
      tar -xzf "$TMP/tofu.tgz" -C "$DEST" tofu ;;
    kubectl)
      telecharger https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl \
        65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8 kubectl
      install -m 0755 "$TMP/kubectl" "$DEST/kubectl" ;;
    kubeconform)
      telecharger https://github.com/yannh/kubeconform/releases/download/v0.7.0/kubeconform-linux-amd64.tar.gz \
        c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3 kubeconform.tgz
      tar -xzf "$TMP/kubeconform.tgz" -C "$DEST" kubeconform ;;
    argo)
      telecharger https://github.com/argoproj/argo-workflows/releases/download/v4.1.5/argo-linux-amd64.gz \
        ab78728d3bcd029f0e8547736e2f3c69d2519a134a3f9ee74454ededa14af36c argo.gz
      gunzip -c "$TMP/argo.gz" > "$DEST/argo" && chmod 0755 "$DEST/argo" ;;
    promtool)
      telecharger https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz \
        2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0 prometheus.tgz
      tar -xzf "$TMP/prometheus.tgz" -C "$TMP"
      install -m 0755 "$TMP/prometheus-3.15.0.linux-amd64/promtool" "$DEST/promtool" ;;
    trivy)
      telecharger https://github.com/aquasecurity/trivy/releases/download/v0.70.0/trivy_0.70.0_Linux-64bit.tar.gz \
        8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9 trivy.tgz
      tar -xzf "$TMP/trivy.tgz" -C "$DEST" trivy ;;
    kind)
      telecharger https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 \
        aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d kind
      install -m 0755 "$TMP/kind" "$DEST/kind" ;;
    *) echo "outil inconnu : $1" >&2; exit 2 ;;
  esac
  echo "installé : $1"
}

for o in "${@:-tofu kubectl kubeconform argo promtool trivy kind}"; do
  for x in $o; do installer "$x"; done
done
