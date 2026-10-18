"""Authentification : empreintes argon2id et tokens JWT signés HS256.

Ce que la v2 corrige par rapport au socle de septembre :
- MD5 remplacé par argon2id (lent par construction, salé, paramétrable) ;
- un seul algorithme accepté, fixé côté serveur : HS256. Un token qui annonce
  "alg": "none" est refusé ;
- tout token porte une expiration (15 minutes par défaut) et un émetteur.
"""

import threading
import time

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError

EMETTEUR = "velocite-api"
_ph = PasswordHasher()

# argon2id consomme 64 Mo de mémoire par vérification, c'est voulu : c'est ce
# qui rend une attaque par force brute coûteuse. Mais quatre connexions
# simultanées font 256 Mo, et le conteneur est limité. On sérialise donc les
# vérifications : deux au plus en même temps. Dimensionner la mémoire d'un
# conteneur, c'est aussi ça.
_VERIFICATIONS = threading.BoundedSemaphore(2)

# Empreinte d'un mot de passe que personne ne connaît : on la vérifie quand le
# compte n'existe pas, pour que la réponse prenne le même temps dans les deux
# cas et ne révèle pas quels emails sont inscrits.
_LEURRE = _ph.hash("compte-inexistant-velocite")


def verifier_mot_de_passe(empreinte, mot_de_passe):
    with _VERIFICATIONS:
        try:
            return _ph.verify(empreinte or _LEURRE, mot_de_passe)
        except (VerifyMismatchError, InvalidHashError):
            return False


def leurre(mot_de_passe):
    verifier_mot_de_passe(_LEURRE, mot_de_passe)


def emettre(secret, ttl, user_id, role):
    maintenant = int(time.time())
    charge = {"sub": str(user_id), "role": role, "iss": EMETTEUR,
              "iat": maintenant, "exp": maintenant + ttl}
    return jwt.encode(charge, secret, algorithm="HS256")


def verifier(secret, token):
    """Retourne les claims, ou lève jwt.InvalidTokenError."""
    return jwt.decode(token, secret, algorithms=["HS256"], issuer=EMETTEUR,
                      options={"require": ["exp", "iat", "sub", "iss"]})
