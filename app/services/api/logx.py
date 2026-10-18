"""Logs au format logfmt (cle=valeur), sur la sortie standard uniquement.

v2 : plus de fichier partagé entre conteneurs. Le collecteur (Alloy, Docker)
lit la sortie standard. Les champs sensibles sont refusés à l'écriture :
un mot de passe, un téléphone ou un email ne sortent jamais dans les logs.
"""

import json
import sys
import time

INTERDITS = {"password", "mot_de_passe", "motdepasse", "phone", "telephone",
             "email", "token", "secret", "authorization", "card", "iban"}


def _valeur(v):
    s = str(v)
    if s == "" or any(c in s for c in ' "=\n'):
        return json.dumps(s, ensure_ascii=False)
    return s


class Logger:
    def __init__(self, service):
        self.service = service

    def event(self, level, event, **kv):
        morceaux = [
            "ts=" + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level=" + level,
            "service=" + self.service,
            "event=" + event,
        ]
        for cle, valeur in kv.items():
            if any(i in cle.lower() for i in INTERDITS):
                valeur = "[masque]"
            morceaux.append("{}={}".format(cle, _valeur(valeur)))
        sys.stdout.write(" ".join(morceaux) + "\n")
        sys.stdout.flush()
