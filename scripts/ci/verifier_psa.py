"""Contrôle hors cluster du profil Pod Security "restricted".

Lit des manifestes YAML (sortie de kubectl kustomize, helm template ou argo)
sur l'entrée standard ou dans des fichiers, et signale chaque gabarit de pod
qui serait refusé par un namespace étiqueté
pod-security.kubernetes.io/enforce=restricted.

Ce n'est pas l'admission du cluster : c'est le même contrôle, plus tôt, dans
la CI. Le cluster reste la référence.

Usage :
  kubectl kustomize deploy/overlays/dev | python scripts/ci/verifier_psa.py
  python scripts/ci/verifier_psa.py rendu.yaml

Code de sortie 1 si un gabarit est non conforme.
"""

import re
import sys

import yaml

VOLUMES_PERMIS = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral",
                  "persistentVolumeClaim", "projected", "secret", "name"}
SYSCTLS_SURS = {"kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range",
                "net.ipv4.ip_unprivileged_port_start", "net.ipv4.tcp_syncookies",
                "net.ipv4.ping_group_range", "net.ipv4.ip_local_reserved_ports",
                "net.ipv4.tcp_keepalive_time", "net.ipv4.tcp_fin_timeout",
                "net.ipv4.tcp_keepalive_intvl", "net.ipv4.tcp_keepalive_probes"}


def gabarits(doc):
    """Renvoie les spécifications de pod contenues dans un objet."""
    if not isinstance(doc, dict):
        return []
    kind = doc.get("kind", "")
    spec = doc.get("spec") or {}
    if kind == "Pod":
        return [spec]
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return [(spec.get("template") or {}).get("spec") or {}]
    if kind == "CronJob":
        return [(((spec.get("jobTemplate") or {}).get("spec") or {})
                 .get("template") or {}).get("spec") or {}]
    if kind in ("Workflow", "WorkflowTemplate", "ClusterWorkflowTemplate",
                "CronWorkflow"):
        return gabarits_argo(doc)
    return []


def gabarits_argo(doc):
    """Un workflow Argo n'est pas un pod : chaque template conteneur en
    devient un. On reconstitue un pod par template, avec le contexte de
    sécurité commun (spec.securityContext) et celui du template."""
    spec = doc.get("spec") or {}
    if doc.get("kind") == "CronWorkflow":
        spec = spec.get("workflowSpec") or {}
    contexte_pod = spec.get("securityContext") or {}
    pods = []
    for t in spec.get("templates") or []:
        if "container" in t or "script" in t:
            c = dict(t.get("container") or t.get("script"))
            c.setdefault("name", t.get("name", "?"))
            pods.append({
                "securityContext": {**contexte_pod,
                                    **(t.get("securityContext") or {})},
                "containers": [c],
                "volumes": spec.get("volumes") or [],
                "_argo": True,
            })
    return pods


def verifier_pod(nom, pod):
    fautes = []
    for champ in ("hostNetwork", "hostPID", "hostIPC"):
        if pod.get(champ):
            fautes.append("{} activé".format(champ))
    for v in pod.get("volumes") or []:
        types = set(v) - VOLUMES_PERMIS
        if types:
            fautes.append("volume {} de type {}".format(
                v.get("name"), ",".join(sorted(types))))
    ctx_pod = pod.get("securityContext") or {}
    for s in ctx_pod.get("sysctls") or []:
        if s.get("name") not in SYSCTLS_SURS:
            fautes.append("sysctl non sûr {}".format(s.get("name")))
    conteneurs = ((pod.get("containers") or []) +
                  (pod.get("initContainers") or []) +
                  (pod.get("ephemeralContainers") or []))
    for c in conteneurs:
        ctx = c.get("securityContext") or {}
        n = c.get("name", "?")
        if ctx.get("privileged"):
            fautes.append("{} : privileged".format(n))
        if ctx.get("allowPrivilegeEscalation") is not False:
            fautes.append("{} : allowPrivilegeEscalation doit valoir false".format(n))
        caps = ctx.get("capabilities") or {}
        if "ALL" not in (caps.get("drop") or []):
            fautes.append("{} : capabilities.drop doit contenir ALL".format(n))
        en_trop = set(caps.get("add") or []) - {"NET_BIND_SERVICE"}
        if en_trop:
            fautes.append("{} : capacités ajoutées {}".format(n, sorted(en_trop)))
        non_root = ctx.get("runAsNonRoot", ctx_pod.get("runAsNonRoot"))
        if non_root is not True:
            fautes.append("{} : runAsNonRoot doit valoir true".format(n))
        uid = ctx.get("runAsUser", ctx_pod.get("runAsUser"))
        if uid == 0:
            fautes.append("{} : runAsUser 0".format(n))
        seccomp = (ctx.get("seccompProfile") or
                   ctx_pod.get("seccompProfile") or {}).get("type")
        if seccomp not in ("RuntimeDefault", "Localhost"):
            fautes.append("{} : seccompProfile RuntimeDefault attendu".format(n))
        for p in c.get("ports") or []:
            if p.get("hostPort"):
                fautes.append("{} : hostPort {}".format(n, p["hostPort"]))
    return ["{} : {}".format(nom, f) for f in fautes]


def main():
    flux = [open(f, encoding="utf-8") for f in sys.argv[1:]] or [sys.stdin]
    fautes, vus = [], 0
    for f in flux:
        # Certains charts laissent une tabulation en fin de ligne, que
        # Kubernetes tolère et que PyYAML refuse.
        texte = re.sub(r"[ \t]+$", "", f.read(), flags=re.M)
        for doc in yaml.safe_load_all(texte):
            for pod in gabarits(doc):
                vus += 1
                nom = "{}/{}".format(doc.get("kind"),
                                     (doc.get("metadata") or {}).get("name"))
                fautes += verifier_pod(nom, pod)
    for faute in fautes:
        print("NON CONFORME " + faute)
    print("{} gabarit(s) de pod contrôlé(s), {} écart(s) au profil restricted"
          .format(vus, len(fautes)))
    return 1 if fautes else 0


if __name__ == "__main__":
    sys.exit(main())
