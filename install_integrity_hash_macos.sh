#!/bin/bash
set -euo pipefail

echo "======================================================"
echo " PWSS Integrity Hash Installer – macOS (CI Mode)"
echo "======================================================"

# ====================================================================
# SETTINGS FROM ENV OR DEFAULTS
# ====================================================================
DB_USER="${DB_USER:-integrity}"
DB_PASSWORD="${DB_PASSWORD:-integrity123}"
DB_NAME="integrity_hash"
PORT=5432
INSTALL_JAVA="${INSTALL_JAVA:-false}"

echo "[INFO] DB_USER=$DB_USER"
echo "[INFO] INSTALL_JAVA=$INSTALL_JAVA"

# ====================================================================
# CHECK HOMEBREW
# ====================================================================
if ! command -v brew &>/dev/null; then
  echo "[ERROR] Homebrew is not installed on runner"
  exit 1
fi
echo "[INFO] Homebrew found"

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

PG_ETC_DIR="$BREW_PREFIX/etc"

# ====================================================================
# INSTALL JAVA (OPTIONAL)
# ====================================================================
if [[ "$INSTALL_JAVA" == "true" ]]; then
  echo "[INFO] Installing Java (JDK 21)..."
  brew install openjdk@21 || true
  brew link --force --overwrite openjdk@21 || true
else
  echo "[INFO] Skipping Java installation"
fi

java -version || echo "[WARN] Java not installed"

# ====================================================================
# INSTALL POSTGRESQL
# ====================================================================
if ! command -v psql &>/dev/null; then
  echo "[INFO] PostgreSQL not found — installing"
  brew install postgresql@17
  export PATH="$(brew --prefix postgresql@17)/bin:$PATH"
fi

echo "[INFO] Starting PostgreSQL service"
brew services restart postgresql@17 || true
sleep 5

PG_VERSION=$(psql --version | awk '{print $3}' | cut -d. -f1)
PG_CONF_PATH="$PG_ETC_DIR/postgresql@${PG_VERSION}/postgresql.conf"

echo "[INFO] PostgreSQL version: ${PG_VERSION}"
echo "[INFO] Config: ${PG_CONF_PATH}"

if [[ ! -f "$PG_CONF_PATH" ]]; then
  echo "[ERROR] PostgreSQL config not found"
  exit 1
fi

# ====================================================================
# SSL CERTS
# ====================================================================
echo "[INFO] Copying SSL certificates"
sudo mkdir -p /usr/local/etc/ssl/private
sudo cp psql_files/psql/cert/p_avocado.crt /usr/local/etc/ssl/
sudo cp psql_files/psql/cert/p_avocado.key /usr/local/etc/ssl/private/
sudo chmod 600 /usr/local/etc/ssl/private/p_avocado.key
sudo chown "$(whoami)" /usr/local/etc/ssl/private/p_avocado.key

echo "[INFO] Configuring SSL"
sed -i '' "s|ssl = off|ssl = on|g" "$PG_CONF_PATH"
sed -i '' "s|#ssl_cert_file =.*|ssl_cert_file = '/usr/local/etc/ssl/p_avocado.crt'|g" "$PG_CONF_PATH"
sed -i '' "s|#ssl_key_file =.*|ssl_key_file = '/usr/local/etc/ssl/private/p_avocado.key'|g" "$PG_CONF_PATH"

echo "[INFO] Restarting PostgreSQL"
brew services restart postgresql
sleep 4

# ====================================================================
# DATABASE SETUP
# ====================================================================
echo "[INFO] Creating user + database"

psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 ||
  psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"

psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 ||
  createdb -O "$DB_USER" "$DB_NAME"

# ====================================================================
# CREATE TABLES
# ====================================================================
echo "[INFO] Creating DB tables"

psql -d "$DB_NAME" <<'EOF'
CREATE TABLE IF NOT EXISTS "time"(id BIGSERIAL PRIMARY KEY, created TIMESTAMPTZ NOT NULL, updated TIMESTAMPTZ NOT NULL);
CREATE TABLE IF NOT EXISTS note(id BIGSERIAL PRIMARY KEY, notes TEXT, prev_notes TEXT, prev_prev_notes TEXT, time_id bigint NOT NULL REFERENCES "time"(id));
CREATE TABLE IF NOT EXISTS file(id BIGSERIAL PRIMARY KEY, path TEXT NOT NULL UNIQUE, basename TEXT NOT NULL, directory TEXT NOT NULL, size bigint NOT NULL, mtime TIMESTAMPTZ NOT NULL);
CREATE TABLE IF NOT EXISTS checksum(id BIGSERIAL PRIMARY KEY, file_id bigint NOT NULL REFERENCES file(id), checksum_sha256 TEXT NOT NULL, checksum_sha3 TEXT NOT NULL, checksum_blake_2b TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS monitored_directory(id SERIAL PRIMARY KEY, path TEXT NOT NULL UNIQUE, is_active BOOLEAN NOT NULL DEFAULT TRUE, time_id bigint NOT NULL REFERENCES "time"(id), last_scanned TIMESTAMPTZ, note_id bigint NOT NULL REFERENCES note(id), baseline_established BOOLEAN NOT NULL DEFAULT FALSE, include_subdirectories BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS scan(id SERIAL PRIMARY KEY, scan_time_id bigint NOT NULL REFERENCES "time"(id), status TEXT NOT NULL, note_id bigint NOT NULL REFERENCES note(id), monitored_directory_id INTEGER NOT NULL REFERENCES monitored_directory(id), is_baseline_scan BOOLEAN NOT NULL);
CREATE TABLE IF NOT EXISTS scan_summary(id BIGSERIAL PRIMARY KEY, scan_id INTEGER NOT NULL REFERENCES scan(id), file_id bigint NOT NULL REFERENCES file(id), checksum_id bigint NOT NULL REFERENCES checksum(id));
CREATE TABLE IF NOT EXISTS diff(id BIGSERIAL PRIMARY KEY, baseline_id bigint NOT NULL REFERENCES scan_summary(id), integrity_fail_id bigint NOT NULL REFERENCES scan_summary(id), time_id bigint NOT NULL REFERENCES "time"(id));
CREATE TABLE IF NOT EXISTS auth(id SERIAL PRIMARY KEY, hash TEXT NOT NULL, auth_time bigint REFERENCES "time"(id) NOT NULL);
CREATE TABLE IF NOT EXISTS "user_"(id SERIAL PRIMARY KEY, username TEXT UNIQUE NOT NULL, auth_id int REFERENCES auth(id) NOT NULL, user_time bigint REFERENCES "time"(id) NOT NULL);
CREATE TABLE IF NOT EXISTS license(id INT PRIMARY KEY, license_data TEXT);
INSERT INTO license(id,license_data) VALUES
(1,'331cd7b3ce491feda6e855dcbf5de4dec5d5211e7776c8e7da4a91026ddab7b7'),
(2,'71b16c484b415c32e6139f95d7276ea351228fbef0af5f7dcbd8bff0484b59b5')
ON CONFLICT DO NOTHING;
EOF

# ====================================================================
# PERMISSIONS + ENV
# ====================================================================
echo "[INFO] Setting execution permissions"
chmod +x setup_enviroment/integrity_hash_enviroment || true
chmod +x ../file_integrity_scanner_app/macos/start_integrity_hash || true

echo "[INFO] Running environment setup"
bash setup_enviroment/integrity_hash_enviroment \
  "$(pwd)/../file_integrity_scanner_app/" \
  "$DB_USER" "$DB_PASSWORD" \
  "truststore_mock_value" "ssl_mock_value"

echo "======================================================"
echo " INSTALLATION COMPLETE!"
echo " Connect using:"
echo " psql -d $DB_NAME -U $DB_USER -h localhost -p $PORT -W"
echo "======================================================"
