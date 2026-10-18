"""Client de stockage objet compatible S3 (Garage en v2).

La clé de l'API n'a que la lecture sur le bucket des pièces KYC. Le stockage
n'est jamais exposé hors du réseau interne : l'API relit la pièce et la sert
elle-même, après contrôle du rôle et avec une ligne d'audit.
"""

import boto3
from botocore.config import Config


class Stockage:
    def __init__(self, endpoint, access, secret, region):
        self.client = boto3.client(
            "s3", endpoint_url=endpoint, aws_access_key_id=access,
            aws_secret_access_key=secret, region_name=region,
            config=Config(signature_version="s3v4",
                          s3={"addressing_style": "path"},
                          retries={"max_attempts": 2},
                          connect_timeout=3, read_timeout=10))

    def lire(self, bucket, cle):
        objet = self.client.get_object(Bucket=bucket, Key=cle)
        return objet["Body"].read(), objet.get("ContentType",
                                               "application/octet-stream")
