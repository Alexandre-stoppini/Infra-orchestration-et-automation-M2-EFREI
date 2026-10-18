"""Accès au référentiel PostgreSQL, avec le rôle svc_api.

Le rôle svc_api ne lit que les colonnes dont l'API a besoin (voir
db/postgres/03-roles.sh). Une connexion par thread, rouverte si elle tombe.
"""

import threading

import psycopg
from psycopg.rows import dict_row

COLONNES_USER = """id, full_name, city, region, role, kyc_ref,
    to_char(created_at, 'YYYY-MM-DD') AS created_at, trips_count"""

COLONNES_TRIP = """id, user_id, vehicle_id,
    to_char(started_at, 'YYYY-MM-DD HH24:MI:SS') AS started_at,
    to_char(ended_at, 'YYYY-MM-DD HH24:MI:SS') AS ended_at,
    start_lat, start_lon, end_lat, end_lon, distance_m, duration_s,
    price_cents, region, payment_status"""


class Store:
    def __init__(self, dsn):
        self.dsn = dsn
        self.local = threading.local()

    def _conn(self):
        c = getattr(self.local, "conn", None)
        if c is None or c.closed or c.broken:
            c = psycopg.connect(self.dsn, autocommit=True, row_factory=dict_row,
                                connect_timeout=5,
                                application_name="velocite-api")
            self.local.conn = c
        return c

    def _tous(self, sql, params=()):
        with self._conn().cursor() as cur:
            cur.execute(sql, params)
            return [dict(r) for r in cur.fetchall()]

    def _un(self, sql, params=()):
        lignes = self._tous(sql, params)
        return lignes[0] if lignes else None

    def ping(self):
        self._un("SELECT 1 AS ok")

    # ------------------------------------------------------------- comptes

    def identifiants(self, email):
        return self._un("SELECT id, role, password_hash FROM users"
                        " WHERE email = %s", (email,))

    def marquer_connexion(self, uid):
        with self._conn().cursor() as cur:
            cur.execute("UPDATE users SET last_login_at = now() WHERE id = %s",
                        (uid,))

    def user(self, uid):
        return self._un("SELECT " + COLONNES_USER + " FROM users WHERE id = %s",
                        (uid,))

    # ------------------------------------------------------------- trajets

    def trajets_du_compte(self, uid, limite):
        return self._tous("SELECT " + COLONNES_TRIP + " FROM trips"
                          " WHERE user_id = %s ORDER BY started_at DESC"
                          " LIMIT %s", (uid, limite))

    def trajets(self, limite, decalage):
        return self._tous("SELECT " + COLONNES_TRIP + " FROM trips"
                          " ORDER BY id LIMIT %s OFFSET %s", (limite, decalage))

    def export_pseudonymise(self, limite, decalage, cle):
        # Pseudonymisation côté base : HMAC-SHA256 à clé, coordonnées arrondies
        # à 1e-3, heure tronquée au quart d'heure. Le user_id ne sort jamais.
        return self._tous(
            "SELECT encode(hmac(user_id::text, %s, 'sha256'), 'hex') AS pseudo,"
            " to_char(date_trunc('hour', started_at) + "
            "   floor(extract(minute FROM started_at) / 15) * interval '15 min',"
            "   'YYYY-MM-DD HH24:MI') AS debut_quart,"
            " round(start_lat::numeric, 3) AS start_lat,"
            " round(start_lon::numeric, 3) AS start_lon,"
            " round(end_lat::numeric, 3) AS end_lat,"
            " round(end_lon::numeric, 3) AS end_lon,"
            " distance_m, duration_s, region"
            " FROM trips ORDER BY id LIMIT %s OFFSET %s",
            (cle, limite, decalage))

    def creer_trajet(self, t):
        with self._conn().cursor() as cur:
            cur.execute(
                "INSERT INTO trips (user_id, vehicle_id, started_at, ended_at,"
                " start_lat, start_lon, end_lat, end_lon, distance_m,"
                " duration_s, price_cents, region, payment_status)"
                " VALUES (%(user_id)s, %(vehicle_id)s, %(started_at)s,"
                " %(ended_at)s, %(start_lat)s, %(start_lon)s, %(end_lat)s,"
                " %(end_lon)s, %(distance_m)s, %(duration_s)s,"
                " %(price_cents)s, %(region)s, %(payment_status)s)"
                " RETURNING id", t)
            return cur.fetchone()["id"]

    def stats_regions(self):
        return self._tous("SELECT region, nb_trajets, distance_totale_m,"
                          " chiffre_affaires_cents FROM v_trips_par_region"
                          " ORDER BY region")

    def stats_heures(self):
        return self._tous("SELECT extract(hour FROM started_at)::int AS heure,"
                          " count(*) AS nb_trajets FROM trips"
                          " GROUP BY 1 ORDER BY 1")

    # ---------------------------------------------------------- facturation

    def factures(self, uid):
        return self._tous(
            "SELECT invoice_ref, period, amount_cents, trips_billed,"
            " card_brand, card_last4, card_expiry, iban_masked,"
            " to_char(paid_at, 'YYYY-MM-DD') AS paid_at"
            " FROM billing WHERE user_id = %s ORDER BY period", (uid,))

    def vehicules(self, limite):
        return self._tous(
            "SELECT id, external_ref, type, model, region, battery_pct,"
            " firmware FROM vehicles ORDER BY id LIMIT %s", (limite,))
