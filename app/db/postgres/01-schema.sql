-- ---------------------------------------------------------------------------
-- VéloCité v2 - schéma du référentiel PostgreSQL
--
-- Appliqué au premier démarrage du conteneur (docker-entrypoint-initdb.d).
-- Par rapport au socle de Sécurité 1 :
--   - plus de password_md5 ni de password_legacy : une empreinte argon2id ;
--   - plus de numéro de carte ni d'IBAN complet : 4 chiffres, jeton, IBAN masqué ;
--   - une table d'agrégats alimentée par le job batch ;
--   - pgcrypto pour la pseudonymisation par HMAC à clé.
-- ---------------------------------------------------------------------------

SET client_min_messages TO WARNING;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id                bigserial PRIMARY KEY,
    email             text NOT NULL UNIQUE,
    full_name         text NOT NULL,
    phone             text,
    birth_date        date,
    city              text,
    region            text,
    role              text NOT NULL DEFAULT 'user',
    password_hash     text NOT NULL DEFAULT '',
    kyc_ref           text,
    created_at        timestamp NOT NULL DEFAULT now(),
    last_login_at     timestamp,
    trips_count       integer NOT NULL DEFAULT 0,
    total_spent_cents integer NOT NULL DEFAULT 0,
    marketing_optin   boolean NOT NULL DEFAULT false,
    app_version       text,
    device_os         text,
    notif_token       text
);
CREATE INDEX idx_users_region ON users (region);

CREATE TABLE vehicles (
    id           bigserial PRIMARY KEY,
    external_ref text NOT NULL UNIQUE,
    type         text NOT NULL,
    model        text,
    region       text,
    battery_pct  integer,
    firmware     text,
    last_seen_at timestamp
);

CREATE TABLE trips (
    id             bigserial PRIMARY KEY,
    user_id        bigint NOT NULL REFERENCES users (id),
    vehicle_id     bigint NOT NULL REFERENCES vehicles (id),
    started_at     timestamp NOT NULL,
    ended_at       timestamp NOT NULL,
    start_lat      double precision NOT NULL,
    start_lon      double precision NOT NULL,
    end_lat        double precision NOT NULL,
    end_lon        double precision NOT NULL,
    distance_m     integer NOT NULL CHECK (distance_m >= 0),
    duration_s     integer NOT NULL CHECK (duration_s >= 0),
    price_cents    integer NOT NULL CHECK (price_cents >= 0),
    region         text,
    payment_status text NOT NULL DEFAULT 'pending'
);
CREATE INDEX idx_trips_user ON trips (user_id);
CREATE INDEX idx_trips_started ON trips (started_at);
CREATE INDEX idx_trips_region ON trips (region);

CREATE TABLE billing (
    id           bigserial PRIMARY KEY,
    user_id      bigint NOT NULL REFERENCES users (id),
    invoice_ref  text NOT NULL,
    period       text NOT NULL,
    amount_cents integer NOT NULL,
    trips_billed integer NOT NULL DEFAULT 0,
    card_last4   text,
    card_brand   text,
    card_expiry  text,
    card_token   text,
    iban_masked  text,
    bic          text,
    created_at   timestamp NOT NULL DEFAULT now(),
    paid_at      timestamp
);
CREATE INDEX idx_billing_user ON billing (user_id);

CREATE TABLE telemetry (
    id          bigserial PRIMARY KEY,
    vehicle_id  bigint NOT NULL,
    ts          timestamp NOT NULL,
    lat         double precision,
    lon         double precision,
    battery_pct integer,
    speed_kmh   double precision,
    firmware    text
);
CREATE INDEX idx_telemetry_vehicle ON telemetry (vehicle_id, ts DESC);
CREATE INDEX idx_telemetry_ts ON telemetry (ts);

-- Alimentée par le job batch (étape aggregate), une ligne par jour, région
-- et heure. La clé primaire rend l'idempotence vérifiable : un doublon est
-- impossible.
CREATE TABLE daily_region_stats (
    jour       date    NOT NULL,
    region     text    NOT NULL,
    heure      integer NOT NULL CHECK (heure BETWEEN 0 AND 23),
    nb_trajets integer NOT NULL,
    distance_m bigint  NOT NULL,
    ca_cents   bigint  NOT NULL,
    PRIMARY KEY (jour, region, heure)
);

CREATE VIEW v_trips_par_region AS
SELECT region,
       count(*)         AS nb_trajets,
       sum(distance_m)  AS distance_totale_m,
       sum(price_cents) AS chiffre_affaires_cents
FROM trips
GROUP BY region;
