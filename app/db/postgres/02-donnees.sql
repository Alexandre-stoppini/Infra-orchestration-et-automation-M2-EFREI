-- VéloCité v2 - chargement des jeux d'amorçage (données inventées).

COPY vehicles (id, external_ref, type, model, region, battery_pct, firmware,
               last_seen_at)
    FROM '/docker-entrypoint-initdb.d/data/vehicles.csv'
    WITH (FORMAT csv, HEADER true);

COPY users (id, email, full_name, phone, birth_date, city, region, role,
            password_hash, kyc_ref, created_at, last_login_at, trips_count,
            total_spent_cents, marketing_optin, app_version, device_os,
            notif_token)
    FROM '/docker-entrypoint-initdb.d/data/users.csv'
    WITH (FORMAT csv, HEADER true, FORCE_NOT_NULL (password_hash));

COPY trips (id, user_id, vehicle_id, started_at, ended_at, start_lat,
            start_lon, end_lat, end_lon, distance_m, duration_s, price_cents,
            region, payment_status)
    FROM '/docker-entrypoint-initdb.d/data/trips.csv'
    WITH (FORMAT csv, HEADER true);

COPY billing (id, user_id, invoice_ref, period, amount_cents, trips_billed,
              card_last4, card_brand, card_expiry, card_token, iban_masked,
              bic, created_at, paid_at)
    FROM '/docker-entrypoint-initdb.d/data/billing.csv'
    WITH (FORMAT csv, HEADER true);

SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users));
SELECT setval(pg_get_serial_sequence('vehicles', 'id'), (SELECT max(id) FROM vehicles));
SELECT setval(pg_get_serial_sequence('trips', 'id'), (SELECT max(id) FROM trips));
SELECT setval(pg_get_serial_sequence('billing', 'id'), (SELECT max(id) FROM billing));
