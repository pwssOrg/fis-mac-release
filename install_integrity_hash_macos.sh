#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# PWSS Integrity Hash Installer – macOS (CI Mode)
# ======================================================
# Run locally with custom DB credentials:
# Lokalt: DB_USER=myuser DB_PASSWORD=mypassword ./install_integrity_hash_macos.sh
#
# Script version: 1.0.1
# PostgreSQL target version: 17
# ======================================================

SCRIPT_VERSION="1.0.1"
PG_TARGET_VERSION="17"

echo "======================================================"
echo " PWSS Integrity Hash Installer – macOS (CI Mode)"
echo " Script version: $SCRIPT_VERSION"
echo " PostgreSQL target version: $PG_TARGET_VERSION"
echo "======================================================"
# ====================================================================
# SETTINGS FROM ENV OR DEFAULTS
# ====================================================================
# Detect GitHub Actions environment
if [ "${GITHUB_ACTIONS}" != "true" ]; then

    ### --- ASK USER FOR DB CREDENTIALS ---

    read -p "Enter database user: " DB_USER

    read -sp "Enter database password: " DB_PASSWORD

    echo ""

else

    ### --- RUN IN GITHUB ACTIONS ---

    DB_USER="${DB_USER:-integrity}"

    DB_PASSWORD="${DB_PASSWORD:-integrity123}"

fi
 
# Debug print

echo "DB_USER: $DB_USER"
DB_NAME="integrity_hash"
PORT=26556
INSTALL_JAVA="${INSTALL_JAVA:-true}"

echo "[INFO] Database user: $DB_USER"
echo "[INFO] Java installation enabled: $INSTALL_JAVA"

# ====================================================================
# CHECK HOMEBREW
# ====================================================================
if ! command -v brew &>/dev/null; then
  echo "[ERROR] Homebrew is not installed. Please install Homebrew first."
  exit 1
fi
echo "[INFO] Homebrew detected."

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

# ====================================================================
# OPTIONAL JAVA INSTALLATION
# ====================================================================
if [[ "$INSTALL_JAVA" == "true" ]]; then
  echo "[INFO] Installing OpenJDK 25..."
  brew install openjdk@25 || true
  brew link --force --overwrite openjdk@25 || true
else
  echo "[INFO] Skipping Java installation."
fi

java -version || echo "[WARN] Java not installed or not linked."

# ====================================================================
# INSTALL POSTGRESQL
# ====================================================================
if ! command -v psql &>/dev/null; then
  echo "[INFO] PostgreSQL not found — installing version 17..."
  brew install postgresql@17
fi

# Make sure PATH includes Postgres binaries
export PATH="$(brew --prefix postgresql@17)/bin:$PATH"

PG_VERSION=$(psql --version | awk '{print $3}' | cut -d. -f1)
PG_DATA_DIR="$(brew --prefix postgresql@${PG_VERSION})/var/postgresql@${PG_VERSION}"
PG_CONF_PATH="$PG_DATA_DIR/postgresql.conf"

echo "[INFO] PostgreSQL version detected: $PG_VERSION"
echo "[INFO] Config path: $PG_CONF_PATH"

# ====================================================================
# STOP POSTGRESQL IF RUNNING
# ====================================================================
echo "[INFO] Stopping PostgreSQL service if running..."
brew services stop postgresql@17 || true
sleep 3

# ====================================================================
# INIT DATABASE IF NEEDED
# ====================================================================
if [[ ! -f "$PG_CONF_PATH" ]]; then
  echo "[INFO] PostgreSQL config not found. Initializing database cluster..."
  initdb -D "$PG_DATA_DIR" -E UTF8 || true
fi

# ====================================================================
# COPY CONFIG AND SSL FILES
# ====================================================================
echo "[INFO] Setting up SSL certificates and passphrase script..."

# Create SSL directories
sudo mkdir -p /usr/local/etc/ssl/private

# Copy certificate and key
sudo cp psql_files/psql/cert/server.crt "$PG_DATA_DIR/server.crt"
sudo cp psql_files/psql/cert/server.key "$PG_DATA_DIR/server.key"

# Set secure permissions for key
sudo chmod 600 "$PG_DATA_DIR/server.key"
sudo chown "$(whoami)" "$PG_DATA_DIR/server.key"

# Copy passphrase script with sudo and make executable
sudo cp psql_files/psql/pass/avocado "$PG_DATA_DIR/ssl_passphrase.sh"
sudo chmod 700 "$PG_DATA_DIR/ssl_passphrase.sh"
sudo chown "$(whoami)" "$PG_DATA_DIR/ssl_passphrase.sh"

# Copy PostgreSQL configuration
cp psql_files/postgresql.conf "$PG_CONF_PATH"

echo "[INFO] SSL certificates and configuration copied successfully."

# ====================================================================
# START POSTGRESQL
# ====================================================================

echo "[INFO] Starting PostgreSQL with new configuration..."

# Detect if running in GitHub Actions
if [ "${GITHUB_ACTIONS}" != "true" ]; then
    # Locally: Restart PostgreSQL using brew
    echo "[INFO] Restarting PostgreSQL service locally..."
    brew services restart postgresql@17
else
    # In GitHub Actions: Manually start PostgreSQL with custom config
    LC_ALL="en_US.UTF-8" /opt/homebrew/opt/postgresql@17/bin/postgres \
      -D /opt/homebrew/var/postgresql@17 -p 26556 &
    sleep 5
fi

# ====================================================================
# DATABASE USER AND DATABASE SETUP
# ====================================================================


PSQL_CONN="psql -p $PORT -d postgres -tAc"

echo "[INFO] Creating database user and database if they do not exist..."


$PSQL_CONN "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 ||
  $PSQL_CONN "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"


$PSQL_CONN "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 ||
  $PSQL_CONN "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"

# ====================================================================
# CREATE TABLES
# ====================================================================

echo "[INFO] Creating tables in database '$DB_NAME'..."

psql -p $PORT -d "$DB_NAME" <<'EOF'
CREATE TABLE IF NOT EXISTS "time"(
    id BIGSERIAL PRIMARY KEY,
    created TIMESTAMPTZ NOT NULL,
    updated TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS note(
    id BIGSERIAL PRIMARY KEY,
    notes TEXT,
    prev_notes TEXT,
    prev_prev_notes TEXT,
    time_id bigint NOT NULL REFERENCES "time"(id)
);

CREATE TABLE IF NOT EXISTS file(
    id BIGSERIAL PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    basename TEXT NOT NULL,
    directory TEXT NOT NULL,
    size bigint NOT NULL,
    mtime TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS checksum(
    id BIGSERIAL PRIMARY KEY,
    file_id bigint NOT NULL REFERENCES file(id),
    checksum_sha256 TEXT NOT NULL,
    checksum_sha3 TEXT NOT NULL,
    checksum_blake_2b TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS monitored_directory(
    id SERIAL PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    time_id bigint NOT NULL REFERENCES "time"(id),
    last_scanned TIMESTAMPTZ,
    note_id bigint NOT NULL REFERENCES note(id),
    baseline_established BOOLEAN NOT NULL DEFAULT FALSE,
    include_subdirectories BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS scan(
    id SERIAL PRIMARY KEY,
    scan_time_id bigint NOT NULL REFERENCES "time"(id),
    status TEXT NOT NULL,
    note_id bigint NOT NULL REFERENCES note(id),
    monitored_directory_id INTEGER NOT NULL REFERENCES monitored_directory(id),
    is_baseline_scan BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS scan_summary(
    id BIGSERIAL PRIMARY KEY,
    scan_id INTEGER NOT NULL REFERENCES scan(id),
    file_id bigint NOT NULL REFERENCES file(id),
    checksum_id bigint NOT NULL REFERENCES checksum(id)
);

CREATE TABLE IF NOT EXISTS diff(
    id BIGSERIAL PRIMARY KEY,
    baseline_id bigint NOT NULL REFERENCES scan_summary(id),
    integrity_fail_id bigint NOT NULL REFERENCES scan_summary(id),
    time_id bigint NOT NULL REFERENCES "time"(id)
);

CREATE TABLE IF NOT EXISTS auth(
    id SERIAL PRIMARY KEY,
    hash TEXT NOT NULL,
    auth_time bigint REFERENCES "time"(id) NOT NULL
);

CREATE TABLE IF NOT EXISTS "user_"(
    id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    auth_id int REFERENCES auth(id) NOT NULL,
    user_time bigint REFERENCES "time"(id) NOT NULL
);

CREATE TABLE IF NOT EXISTS license(
    id INT PRIMARY KEY,
    license_data TEXT
);

INSERT INTO license(id,license_data) VALUES
    (1,'331cd7b3ce491feda6e855dcbf5de4dec5d5211e7776c8e7da4a91026ddab7b7'),
    (2,'71b16c484b415c32e6139f95d7276ea351228fbef0af5f7dcbd8bff0484b59b5')
ON CONFLICT DO NOTHING;
EOF

# --- SET TABLE & DB OWNERSHIP ---
TABLES=(time note file checksum monitored_directory scan scan_summary diff auth user_ license)

for t in "${TABLES[@]}"; do
    sudo -u postgres psql -d "$DB_NAME" -p $PORT -c "ALTER TABLE IF EXISTS \"$t\" OWNER TO \"$DB_USER\";"
done

sudo -u postgres psql -p $PORT -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\";"

echo "[INFO] Database setup complete!"
# ====================================================================
# OPTIONAL EXECUTION PERMISSIONS (COMMENTED)
# ====================================================================
 echo "[INFO] Setting executable permissions for environment scripts"
 chmod +x setup_enviroment/integrity_hash_enviroment || true
 chmod +x file_integrity_scanner_app/macos/start_integrity_hash || true

# ====================================================================
# ENVIRONMENT SETUP
# ====================================================================

echo "[INFO] Running environment setup script..."
bash setup_enviroment/integrity_hash_enviroment "$DB_USER" "$DB_PASSWORD" "truststore_mock_value" "ssl_mock_value"

echo "======================================================"
echo " INSTALLATION COMPLETE!"
echo " Connect using:"
echo " psql -d $DB_NAME -U $DB_USER -h localhost -p $PORT -W"
echo "======================================================"
