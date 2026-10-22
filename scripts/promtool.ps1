<#
.SYNOPSIS
  Lance promtool, l'outil de Prometheus qui vérifie et teste les règles,
  dans le conteneur de Prometheus : rien à installer sur le poste.

.EXAMPLE
  .\scripts\promtool.ps1 check rules observability/regles/alertes.yaml
  .\scripts\promtool.ps1 test rules observability/tests/alertes_test.yaml
  pwsh ./scripts/promtool.ps1 test rules observability/tests/alertes_test.yaml   # macOS, Linux

  Les chemins sont relatifs à la racine du dépôt, d'où que le script soit
  lancé. Même version que la CI (scripts/ci/outils.sh) : Prometheus 3.15.0.
#>
. "$PSScriptRoot/commun.ps1"

if ($args.Count -eq 0) { throw "Usage : promtool.ps1 check rules FICHIER, ou test rules FICHIER" }
[string[]]$options = @($args)
& docker run --rm -v "$($Racine):/w" -w /w --entrypoint promtool mirror.gcr.io/prom/prometheus:v3.15.0 @options
exit $LASTEXITCODE
