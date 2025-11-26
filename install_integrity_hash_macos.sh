#!/bin/bash
set -euo pipefail
echo "======================================================"
echo " PWSS Integrity Hash Installer – macOS"
echo "======================================================"
# --- Check Homebrew ---
if ! command -v brew &>/dev/null; then
 echo "[ERROR] Homebrew is not installed."
 echo "Install using:"
 echo '/bin/bash -c "$(curl -fsSL
https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
 exit 1
fi
echo "[INFO] Homebrew found."
# --- Detect chip type (Intel or Apple Silicon) ---
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
 BREW_PREFIX="/opt/homebrew"
else
 BREW_PREFIX="/usr/local"
fi
PG_DATA_DIR="$BREW_PREFIX/var/postgresql"
PG_ETC_DIR="$BREW_PREFIX/etc"
PG_VERSION="15" # Will detect dynamically later
# ====================================================================
# INSTALLATION OF JAVA (JDK)
# ====================================================================
read -p "Install Java (JDK 21 or 25)? [y/N]: " INSTALL_JAVA
if [[ "$INSTALL_JAVA" =~ ^[Yy]$ ]]; then
 echo "[INFO] Installing Java..."
 if brew search openjdk@25 | grep -q openjdk@25; then
 brew install openjdk@25
 JAVA_VERSION=25
 elif brew search openjdk@21 | grep -q openjdk@21; then
 brew install openjdk@21
 JAVA_VERSION=21
 else
 echo "[ERROR] Neither JDK 25 nor JDK 21 found in Homebrew."
 exit 1
 fi
 echo "[INFO] Java installation complete."
 java -version || true
else
 echo "[INFO] Java installation skipped."
fi
# ====================================================================
# INSTALLATION OF POSTGRESQL
# ====================================================================
if ! command -v psql &>/dev/null; then
 echo "[INFO] Installing PostgreSQL via Homebrew..."
 brew install postgresql
else
 echo "[INFO] PostgreSQL is already installed."
fi
echo "[INFO] Starting PostgreSQL..."
brew services start postgresql
sleep 3
# --- Detect PG version ---
PG_VERSION=$(psql --version | awk '{print $3}' | cut -d. -f1)
PG_CONF_PATH="$PG_ETC_DIR/postgresql@${PG_VERSION}/postgresql.conf"
PG_DATA_PATH="$BREW_PREFIX/var/postgresql@${PG_VERSION}"
echo "[INFO] Detected PostgreSQL major version: $PG_VERSION"
echo "[INFO] postgres.conf located at: $PG_CONF_PATH"
if [[ ! -f "$PG_CONF_PATH" ]]; then
 echo "[ERROR] postgresql.conf not found at $PG_CONF_PATH"
 exit 1
fi
# ====================================================================
# SSL CONFIG & CERT INSTALLATION
# ====================================================================
echo "[INFO] Copying PostgreSQL SSL certs..."
sudo mkdir -p /usr/local/etc/ssl
sudo mkdir -p /usr/local/etc/ssl/private
sudo cp psql_files/psql/cert/p_avocado.crt /usr/local/etc/ssl/
sudo cp psql_files/psql/cert/p_avocado.key /usr/local/etc/ssl/private/
sudo chmod 600 /usr/local/etc/ssl/private/p_avocado.key
sudo chown "$(whoami)" /usr/local/etc/ssl/private/p_avocado.key
echo "[INFO] Updating postgresql.conf with SSL parameters..."
# Equivalent sed for macOS (requires '' as backup suffix)
sed -i '' "s|ssl = off|ssl = on|g" "$PG_CONF_PATH"
sed -i '' "s|#ssl_cert_file =.*|ssl_cert_file = '/usr/local/etc/ssl/p_avocado.crt'|g" "$PG_CONF_PATH"
sed -i '' "s|#ssl_key_file =.*|ssl_key_file = '/usr/local/etc/ssl/private/p_avocado.key'|g"
"$PG_CONF_PATH"
echo "[INFO] Restarting PostgreSQL with SSL..."
brew services restart postgresql
sleep 3
# ====================================================================
# SETUP DATABASE & TABLES
# ====================================================================
read -p "Enter database user: " DB_USER
read -sp "Enter database password: " DB_PASSWORD
echo ""
DB_NAME="integrity_hash"
PORT=5432 # default on macOS Homebrew unless overridden
# --- Create role if missing ---
USER_EXISTS=$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" || true)
if [[ "$USER_EXISTS" != "1" ]]; then
 echo "[INFO] Creating user $DB_USER..."
 psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
else
 echo "[INFO] User $DB_USER already exists."
fi
# --- Create database ---
DB_EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" || true)
if [[ "$DB_EXISTS" != "1" ]]; then
 echo "[INFO] Creating database $DB_NAME..."
 createdb -O "$DB_USER" "$DB_NAME"
else
 echo "[INFO] Database already exists."
fi
# --- Create tables ---
echo "[INFO] Creating tables..."
psql -d "$DB_NAME" <<'EOF'
CREATE TABLE IF NOT EXISTS "time"(id BIGSERIAL PRIMARY KEY, created TIMESTAMPTZ NOT NULL,
updated TIMESTAMPTZ NOT NULL);
CREATE TABLE IF NOT EXISTS note (id BIGSERIAL PRIMARY KEY, notes TEXT, prev_notes TEXT,
prev_prev_notes TEXT, time_id bigint NOT NULL REFERENCES "time"(id));
CREATE TABLE IF NOT EXISTS file (id BIGSERIAL PRIMARY KEY, path TEXT NOT NULL UNIQUE,
basename TEXT NOT NULL, directory TEXT NOT NULL, size bigint NOT NULL, mtime TIMESTAMPTZ
NOT NULL);
CREATE TABLE IF NOT EXISTS checksum (id BIGSERIAL PRIMARY KEY, file_id bigint NOT NULL
REFERENCES file(id), checksum_sha256 TEXT NOT NULL, checksum_sha3 TEXT NOT NULL,
checksum_blake_2b TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS monitored_directory (id SERIAL PRIMARY KEY, path TEXT NOT NULL
UNIQUE, is_active BOOLEAN NOT NULL DEFAULT TRUE, time_id bigint NOT NULL REFERENCES
"time"(id), last_scanned TIMESTAMPTZ, note_id bigint NOT NULL REFERENCES note(id),
baseline_established BOOLEAN NOT NULL DEFAULT FALSE, include_subdirectories BOOLEAN NOT
NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS scan (id SERIAL PRIMARY KEY, scan_time_id bigint NOT NULL
REFERENCES "time"(id), status TEXT NOT NULL, note_id bigint NOT NULL REFERENCES note(id),
monitored_directory_id INTEGER NOT NULL REFERENCES monitored_directory(id), is_baseline_scan
BOOLEAN NOT NULL);
CREATE TABLE IF NOT EXISTS scan_summary (id BIGSERIAL PRIMARY KEY, scan_id INTEGER NOT NULL
REFERENCES scan(id), file_id bigint NOT NULL REFERENCES file(id), checksum_id bigint NOT NULL
REFERENCES checksum(id));
CREATE TABLE IF NOT EXISTS diff (id BIGSERIAL PRIMARY KEY, baseline_id bigint NOT NULL
REFERENCES scan_summary(id), integrity_fail_id bigint NOT NULL REFERENCES scan_summary(id),
time_id bigint NOT NULL REFERENCES "time"(id));
CREATE TABLE IF NOT EXISTS auth(id SERIAL PRIMARY KEY, hash TEXT NOT NULL, auth_time bigint
REFERENCES "time"(id) NOT NULL);
CREATE TABLE IF NOT EXISTS "user_"(id SERIAL PRIMARY KEY, username TEXT UNIQUE NOT NULL,
auth_id int REFERENCES auth(id) NOT NULL, user_time bigint REFERENCES "time"(id) NOT NULL);
CREATE TABLE IF NOT EXISTS license(id INT PRIMARY KEY, license_data TEXT);
INSERT INTO license (id,license_data) VALUES
(1,'331cd7b3ce491feda6e855dcbf5de4dec5d5211e7776c8e7da4a91026ddab7b7'),
(2,'71b16c484b415c32e6139f95d7276ea351228fbef0af5f7dcbd8bff0484b59b5')
ON CONFLICT DO NOTHING;
EOF
# ====================================================================
# ENVIRONMENT SETUP FOR INTEGRITY HASH
# ====================================================================
echo "[INFO] Setting execution permissions..."
chmod +x setup_enviroment/integrity_hash_enviroment || true
chmod +x ../file_integrity_scanner_app/macos/start_integrity_hash || true
echo "[INFO] Running environment script..."
bash setup_enviroment/integrity_hash_enviroment \
 "$(realpath ../file_integrity_scanner_app/)" \
 "$DB_USER" "$DB_PASSWORD" \
 "truststore_mock_value" "ssl_mock_value"
echo ""
echo "======================================================"
echo " Installation complete!"
echo " Connect using: psql -d $DB_NAME -U $DB_USER -h localhost -p $PORT -W"
echo "======================================================"