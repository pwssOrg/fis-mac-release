#!/usr/bin/env bash
set -euo pipefail

exec 1>&2 # Skickar all standard output till stderr
set -x ## Gör Bash mer verbose

# ======================================================
# PWSS Integrity Hash Installer – macOS (CI Mode)
# ======================================================
# Run locally with custom DB credentials:
# Lokalt: DB_USER=myuser DB_PASSWORD=mypassword ./install_integrity_hash_macos.sh
#
# Script version: 1.2.2
# PostgreSQL target version: 17
# ======================================================

SCRIPT_VERSION="1.2.2"
PG_TARGET_VERSION="17"

echo "======================================================"
echo " PWSS Integrity Hash Installer – macOS (CI Mode)"
echo " Script version: $SCRIPT_VERSION"
echo " PostgreSQL target version: $PG_TARGET_VERSION"
echo "======================================================"
# ====================================================================
# SETTINGS FROM ENV OR DEFAULTS
# ====================================================================

GITHUB_ACTIONS=false
# Detect GitHub Actions environment
if [ -z "${GITHUB_ACTIONS}" ] || [ "${GITHUB_ACTIONS}" != "true" ]; then


DB_USER="${INSTALLER_USER_INPUT_DB_USER:-defaultuser}"
DB_PASSWORD="${INSTALLER_USER_INPUT_DB_PASSWORD:-defaultpassword}"

else

    ### --- RUN IN GITHUB ACTIONS ---

    DB_USER="${DB_USER:-integrity}"

    DB_PASSWORD="${DB_PASSWORD:-integrity123}"

fi
 


echo "DB_USER: $DB_USER"
DB_NAME="integrity_hash"
PORT=26556
INSTALL_JAVA="${INSTALL_JAVA:-true}"

echo "[INFO] Database user: $DB_USER"
echo "[INFO] Java installation enabled: $INSTALL_JAVA"

# ====================================================================
# CHECK HOMEBREW
# ====================================================================

if command -v brew >/dev/null 2>&1; then
    echo "Homebrew is already installed."
    echo "Updating Homebrew..."
    brew update
else
    echo "Homebrew not found. Installing..."
 
    # Install Homebrew (non-interactive)
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
 
    # Add Homebrew to PATH depending on architecture
    if [[ -d "/opt/homebrew/bin" ]]; then
        # Apple Silicon
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -d "/usr/local/bin" ]]; then
        # Intel mac
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ====================================================================
# JAVA INSTALLATION
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
PG_DATA_DIR_HOMEBREW="/opt/homebrew/var/postgresql@${PG_VERSION}"
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

# Copy certificate and key
 cp /usr/local/pwss_installer/psql_files/psql/cert/server.crt "$PG_DATA_DIR/server.crt"
 chown "$(whoami)" "$PG_DATA_DIR/server.crt"

 cp "$PG_DATA_DIR/server.crt" "$PG_DATA_DIR_HOMEBREW/server.crt"
 chown "$(whoami)" "$PG_DATA_DIR_HOMEBREW/server.crt"

# Set secure permissions for key
 cp /usr/local/pwss_installer/psql_files/psql/cert/server.key "$PG_DATA_DIR/server.key"
 chmod 600 "$PG_DATA_DIR/server.key"
 chown "$(whoami)" "$PG_DATA_DIR/server.key"

 cp "$PG_DATA_DIR/server.key" "$PG_DATA_DIR_HOMEBREW/server.key"
 chmod 600 "$PG_DATA_DIR_HOMEBREW/server.key"
 chown "$(whoami)" "$PG_DATA_DIR_HOMEBREW/server.key"

# Copy passphrase script with sudo and make executable
 cp /usr/local/pwss_installer/psql_files/psql/pass/avocado "$PG_DATA_DIR/ssl_passphrase.sh"
 chmod 700 "$PG_DATA_DIR/ssl_passphrase.sh"
 chown "$(whoami)" "$PG_DATA_DIR/ssl_passphrase.sh"

 cp "$PG_DATA_DIR/ssl_passphrase.sh" "$PG_DATA_DIR_HOMEBREW/ssl_passphrase.sh"
 chmod 700 "$PG_DATA_DIR_HOMEBREW/ssl_passphrase.sh"
 chown "$(whoami)" "$PG_DATA_DIR_HOMEBREW/ssl_passphrase.sh"

# Copy PostgreSQL configuration
cp /usr/local/pwss_installer/psql_files/postgresql.conf "$PG_CONF_PATH"
cp "$PG_CONF_PATH" "$PG_DATA_DIR_HOMEBREW/postgresql.conf"

echo "PG_DATA_DIR: $PG_DATA_DIR"
echo "PG_CONF_PATH: $PG_CONF_PATH"

ls -l "$PG_DATA_DIR/server.crt"

ls -l "$PG_DATA_DIR/server.key"

ls -l "$PG_DATA_DIR/ssl_passphrase.sh"

echo "[INFO] SSL certificates and configuration copied successfully."

# ====================================================================
# EXECUTION PERMISSIONS
# ====================================================================
echo "[INFO] Setting executable permissions for environment script"
chmod +x /usr/local/pwss_installer/integrity_hash_enviroment || true

# ====================================================================
# ENVIRONMENT SETUP
# ====================================================================
echo "[INFO] Running environment setup script..."
# Use GitHub secrets if available, otherwise fall back to defaults
TRUSTSTORE="${TRUSTSTORE_FIS_GUI:-mock_truststore}"
SSL_FILE="${ssl_file_integrity_scanner:-mock_ssl}"

bash /usr/local/pwss_installer/integrity_hash_enviroment "$DB_USER" "$DB_PASSWORD" "$TRUSTSTORE" "$SSL_FILE"

# ====================================================================
# START POSTGRESQL
# ====================================================================

echo "[INFO] Starting PostgreSQL with new configuration..."

# Detect if running in GitHub Actions
if [ "${GITHUB_ACTIONS}" != "true" ]; then
    # Locally: Restart PostgreSQL using brew
    echo "[INFO] Restarting PostgreSQL service locally..."
    #brew services restart postgresql@17
    # Start PostgreSQL in the background and save the PID
    echo "[INFO] Starting PostgreSQL with custom configuration..."

    LC_ALL="en_US.UTF-8" /opt/homebrew/opt/postgresql@17/bin/postgres -D /opt/homebrew/var/postgresql@17 -p 26556 &

    PG_PID=$!
 
    # Wait for a few seconds to ensure PostgreSQL has started
    sleep 5
 
    # Check if PostgreSQL is running by checking the PID
    if ps -p $PG_PID > /dev/null; then
      echo "[INFO] PostgreSQL started successfully with PID $PG_PID."
    else
       echo "[ERROR] Failed to start PostgreSQL."
       exit 1
    fi
 
    # Continue with database setup
    echo "[INFO] Database setup continues..."
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

psql -U "$DB_USER" -p $PORT -d "$DB_NAME" <<'EOF'
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
 
# Loop through each table and change ownership
 for t in "${TABLES[@]}"; do
     # Check if the table is 'time' and add quotes if true
     if [[ "$t" == "time" ]]; then
         t="\"$t\""
     fi

     # Use psql with the correct PostgreSQL user and password
     PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -p "$PORT" -c "ALTER TABLE IF EXISTS $t OWNER TO \"$DB_USER\";"
done
 
# Alter database ownership
PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -p "$PORT" -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\";"
 
echo "[INFO] Database setup complete!"

# ====================================================================
# Setting psql executable to path
# ====================================================================
export PATH="$(brew --prefix postgresql@17)/bin:$PATH"

echo "======================================================"
echo " INSTALLATION COMPLETE!"
echo " Connect using:"
echo " psql -d $DB_NAME -U $DB_USER -h localhost -p $PORT -W"
echo "======================================================"
