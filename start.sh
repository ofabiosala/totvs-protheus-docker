#!/usr/bin/env bash

set -Eeuo pipefail

# ========================================================
# TOTVS PROTHEUS - AMBIENTE DOCKER
# Compatibilidade: GNU/Linux e macOS (Bash 3.2+)
# ========================================================

export LC_ALL="${LC_ALL:-C}"

# ========================================================
# CONFIGURACAO INICIAL
# ========================================================

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

SHARED_DIR="$PROJECT_ROOT/shared"
CONFIG_FILE="$PROJECT_ROOT/config/download.json"
ENV_FILE="$PROJECT_ROOT/.env"
ENV_EXAMPLE_FILE="$PROJECT_ROOT/.env.example"

# Containers
DB_CONTAINER="tp-db"
LICENSE_CONTAINER="tp-licenseserver"
DBACCESS_CONTAINER="tp-dbaccess"
APPSERVER_CONTAINER="tp-appserver"
SMARTVIEW_CONTAINER="tp-smartview"

# Arquivos
LICENSE_ARCHIVE="LICENSE.TAR"
DBACCESS_ARCHIVE="DBACCESS.TAR"
APPSERVER_ARCHIVE="APPSERVER.TAR"
SMARTVIEW_ARCHIVE="SMART_VIEW.zip"

# Diretórios Alvo Internos
LICENSE_TARGET="/totvs/licenseserver"
DBACCESS_TARGET="/totvs/protheus/bin/dbaccess"
APPSERVER_TARGET="/totvs/protheus/bin/appserver"
APO_TARGET="/totvs/protheus/bin/apo"
SMARTVIEW_TARGET="/usr/sbin/smart-view"

# ========================================================
# INTERFACE E TRATAMENTO DE ERROS
# ========================================================

show_header() {
    printf '\n\033[1;30m========================================================\033[0m\n'
    printf '  \033[1;36m%s\033[0m\n' "$1"
    printf '\033[1;30m========================================================\033[0m\n\n'
}

show_step() { printf '\033[1;33m [+] %s\033[0m\n' "$1"; }
show_success() { printf '\033[1;32m [OK] %s\033[0m\n' "$1"; }
show_fail() { printf '\033[1;31m [ERRO] %s\033[0m\n' "$1" >&2; }
show_warning() { printf '\033[1;33m [!] %s\033[0m\n' "$1"; }

die() { show_fail "$1"; exit 1; }

on_error() {
    local exit_code=$?
    local line="${1:-desconhecida}"
    show_fail "Erro na linha ${line}. Codigo de saida: ${exit_code}."
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

command_exists() { command -v "$1" >/dev/null 2>&1; }
require_command() { command_exists "$1" || die "Comando '$1' nao encontrado."; }

# ========================================================
# FUNCOES AUXILIARES (DOWNLOAD, HASH, JSON)
# ========================================================

read_json_field() {
    local json_file="$1"
    local field="$2"
    python3 - "$json_file" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8-sig") as f:
        print(str(json.load(f).get(field, "")).strip())
except Exception:
    sys.exit(1)
PY
}

calculate_sha256() {
    if command_exists sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif command_exists shasum; then shasum -a 256 "$1" | awk '{print $1}'
    elif command_exists openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else die "Nenhuma ferramenta SHA-256 encontrada."; fi
}

download_file() {
    local url="$1" destination="$2" temp_file="${2}.part"
    show_step "Baixando arquivo de dependencias..."
    rm -f "$temp_file"
    if command_exists curl; then
        curl --fail --location --retry 3 --progress-bar --output "$temp_file" "$url" || die "Falha no curl."
    elif command_exists wget; then
        wget --tries=3 --show-progress --output-document="$temp_file" "$url" || die "Falha no wget."
    else
        die "Instale curl ou wget."
    fi
    [[ -s "$temp_file" ]] || die "Arquivo baixado vazio."
    mv -f "$temp_file" "$destination"
    show_success "Download concluido."
}

# ========================================================
# 1. VALIDACAO E CONFIGURACAO INICIAL
# ========================================================
clear || true
show_header "TOTVS PROTHEUS - AMBIENTE DOCKER (FULL STACK)"

require_command python3
require_command docker
require_command tar
require_command awk

show_step "Validando arquivo de configuracao..."
[[ -f "$CONFIG_FILE" ]] || die "Arquivo $CONFIG_FILE nao encontrado."
DOWNLOAD_URL="$(read_json_field "$CONFIG_FILE" url)"
EXPECTED_HASH="$(read_json_field "$CONFIG_FILE" sha256)"
[[ "$DOWNLOAD_URL" =~ ^https?:// ]] || die "URL invalida."
show_success "Arquivo configuracao validado."

mkdir -p "$SHARED_DIR"
FULL_ARCHIVE="$SHARED_DIR/full.tar"

# ========================================================
# 2. DOWNLOAD E EXTRACAO
# ========================================================
if [[ ! -f "$SHARED_DIR/$DBACCESS_ARCHIVE" ]]; then
    download_file "$DOWNLOAD_URL" "$FULL_ARCHIVE"
    show_step "Validando hash SHA-256..."
    ACTUAL_HASH="$(calculate_sha256 "$FULL_ARCHIVE")"
    if [[ "${ACTUAL_HASH,,}" != "${EXPECTED_HASH,,}" ]]; then
        rm -f "$FULL_ARCHIVE"
        die "O hash nao confere! Esperado: $EXPECTED_HASH | Recebido: $ACTUAL_HASH"
    fi
    show_success "Hash validado."
    
    show_step "Extraindo dependencias..."
    tar -xf "$FULL_ARCHIVE" -C "$SHARED_DIR" || die "Falha ao extrair TAR."
    rm -f "$FULL_ARCHIVE"
    show_success "Dependencias extraidas."
fi

# ========================================================
# 3. ESTRUTURA DE DIRETORIOS E SERVICOS
# ========================================================
show_step "Criando estrutura de diretorios e servicos..."

DIRECTORIES=(
    "config" "config/dbaccess"
    "docker/licenseserver" "docker/dbaccess"
    "docker/appserver/apo" "docker/smartview"
    "protheus_data/system" "protheus_data/systemload"
    "db/init" "db/backups"
)
for dir in "${DIRECTORIES[@]}"; do 
    mkdir -p "$PROJECT_ROOT/$dir"
    chmod 777 "$PROJECT_ROOT/$dir" # Força permissão local
done

# Garante a criacao de arquivos vazios ANTES do docker compose rodar
FILES=(
    "docker/licenseserver/appserver.ini"
    "docker/dbaccess/dbaccess.ini"
    "docker/appserver/appserver.ini"
    "config/dbaccess/odbc.ini"
    "config/dbaccess/odbcinst.ini"
)
for file in "${FILES[@]}"; do
    if [[ -d "$PROJECT_ROOT/$file" ]]; then
        rm -rf "$PROJECT_ROOT/$file" 
    fi
    touch "$PROJECT_ROOT/$file"
    chmod 666 "$PROJECT_ROOT/$file" # Força permissão de leitura/escrita local
done

# Criação de Serviços Systemd
cat << 'EOF' > "$PROJECT_ROOT/config/license-server.service"
[Unit]
Description=TOTVS License Server
[Service]
Type=simple
WorkingDirectory=/totvs/licenseserver/bin/appserver
ExecStart=/totvs/licenseserver/bin/appserver/appsrvlinux
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > "$PROJECT_ROOT/config/dbaccess.service"
[Unit]
Description=TOTVS DBAccess
[Service]
Type=simple
WorkingDirectory=/totvs/protheus/bin/dbaccess
ExecStart=/totvs/protheus/bin/dbaccess/multi/dbaccess64
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > "$PROJECT_ROOT/config/appserver.service"
[Unit]
Description=TOTVS AppServer
[Service]
Type=simple
WorkingDirectory=/totvs/protheus/bin/appserver
ExecStart=/totvs/protheus/bin/appserver/appsrvlinux
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > "$PROJECT_ROOT/config/smart-view-agent.service"
[Unit]
Description=smart-view-agent
[Service]
Type=simple
WorkingDirectory=/usr/sbin/smart-view
ExecStart=/usr/sbin/smart-view/TReports.Agent --urls http://*:7019
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > "$PROJECT_ROOT/config/dbaccess/odbcinst.ini"
[PostgreSQL ANSI]
Description=PostgreSQL ODBC driver (ANSI version)
Driver=psqlodbc.so
Setup=libodbcpsqlS.so
Debug=0
CommLog=1
UsageCount=1

[PostgreSQL Unicode]
Description=PostgreSQL ODBC driver (Unicode version)
Driver=psqlodbcw.so
Setup=libodbcpsqlS.so
Debug=0
CommLog=1
UsageCount=1
EOF

cat << 'EOF' > "$PROJECT_ROOT/.dockerignore"
shared/
*.tar
*.zip
.git/
.env
EOF

cat << 'EOF' > "$PROJECT_ROOT/.gitignore"
.env
/db/data/
/db/backups/
/shared/
*.tar
*.zip
/docker/licenseserver/*
!/docker/licenseserver/*.ini
/docker/dbaccess/*
!/docker/dbaccess/*.ini
/docker/appserver/*
!/docker/appserver/*.ini
!/docker/appserver/apo/
/docker/appserver/apo/*
!/docker/appserver/apo/*.rpo
/docker/smartview/*
!/docker/smartview/*.ini
EOF
show_success "Estrutura pronta."

# ========================================================
# 4. ARQUIVOS DE AMBIENTE (.ENV)
# ========================================================
show_step "Configurando arquivo de ambiente (.env)..."
if [[ ! -f "$ENV_FILE" ]]; then
    cat << 'EOF' > "$ENV_FILE"
POSTGRES_DB=protheus
POSTGRES_USER=postgres
POSTGRES_PASSWORD=protheus_pwd
POSTGRES_PORT=5432
APPSERVER_PORT=1234
DBACCESS_PORT=7890
LICENSESERVER_PORT=5555
SHARED_DIR=./shared
TZ=America/Sao_Paulo
EOF
    cp "$ENV_FILE" "$ENV_EXAMPLE_FILE"
fi

# Exportar variaveis do .env para uso no script
set -a
source "$ENV_FILE"
set +a
show_success "Variaveis carregadas."

# ========================================================
# 5. DOCKER & DOCKER COMPOSE
# ========================================================
show_step "Subindo containers via Docker Compose..."
docker info >/dev/null 2>&1 || die "Docker nao acessivel."
docker compose version >/dev/null 2>&1 || die "Docker Compose indisponivel."

COMPOSE_FILE=""
for c in docker-compose.yml compose.yaml compose.yml docker-compose.yaml; do
    [[ -f "$PROJECT_ROOT/$c" ]] && COMPOSE_FILE="$PROJECT_ROOT/$c" && break
done
[[ -n "$COMPOSE_FILE" ]] || die "Arquivo Compose nao encontrado."

docker pull postgres:16 >/dev/null
docker pull oraclelinux:10 >/dev/null
docker compose -f "$COMPOSE_FILE" up -d || die "Falha ao iniciar containers."
show_success "Containers inicializados."

show_step "Forcando fuso horario (America/Sao_Paulo) nos containers..."
for container in "$DB_CONTAINER" "$LICENSE_CONTAINER" "$DBACCESS_CONTAINER" "$APPSERVER_CONTAINER" "$SMARTVIEW_CONTAINER"; do
    docker exec -u root "$container" bash -c "ln -snf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime && echo 'America/Sao_Paulo' > /etc/timezone" >/dev/null 2>&1 || true
done
show_success "Fuso horario atualizado."


# ========================================================
# 6. BANCO DE DADOS (POSTGRESQL 16)
# ========================================================

show_step "Configurando Banco de Dados PostgreSQL 16..."

PG_BIN="/usr/lib/postgresql/16/bin"
PG_RESTORE="$PG_BIN/pg_restore"
PG_DUMP="$PG_BIN/pg_dump"
PSQL="$PG_BIN/psql"

printf "     Aguardando PostgreSQL...\n"

db_ready=0

for i in {1..30}; do
    if docker exec -u postgres "$DB_CONTAINER" \
        "$PG_BIN/pg_isready" -t 1 >/dev/null 2>&1; then
        db_ready=1
        break
    fi
    sleep 2
done

[[ "$db_ready" -eq 1 ]] || die "PostgreSQL offline."

# --------------------------------------------------------
# Verificar binarios PostgreSQL 16
# --------------------------------------------------------

show_step "Verificando binarios PostgreSQL 16..."

for binary in pg_restore pg_dump psql pg_isready; do
    docker exec "$DB_CONTAINER" \
        test -x "$PG_BIN/$binary" \
        || die "Binario PostgreSQL 16 nao encontrado: $binary"
done

PG_RESTORE_VERSION=$(
    docker exec "$DB_CONTAINER" "$PG_RESTORE" --version
)

printf "     %s\n" "$PG_RESTORE_VERSION"

show_success "Binarios PostgreSQL 16 encontrados."

# --------------------------------------------------------
# Preparar diretorios
# --------------------------------------------------------

docker exec "$DB_CONTAINER" bash -c \
    "mkdir -p /postgres/pg_data/$POSTGRES_DB/data \
    /postgres/pg_data/$POSTGRES_DB/index \
    /postgres/pg_data/$POSTGRES_DB/backup"

docker exec "$DB_CONTAINER" chown -R postgres:postgres /postgres

# --------------------------------------------------------
# Configurar usuario e tablespaces
# --------------------------------------------------------

show_step "Configurando usuarios e tablespaces..."

cat << EOF > "$SHARED_DIR/setup_db.sh"
#!/bin/bash
set -e

PG_BIN="/usr/lib/postgresql/16/bin"
PSQL="\$PG_BIN/psql"

"\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
"ALTER USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"

"\$PSQL" -d template1 -tAc \
"SELECT 1 FROM pg_roles WHERE rolname='protheus'" | grep -q 1 || \
"\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
"CREATE USER protheus WITH LOGIN NOSUPERUSER INHERIT CREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT -1 PASSWORD '$POSTGRES_PASSWORD';"

"\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
"ALTER ROLE protheus WITH PASSWORD '$POSTGRES_PASSWORD';"

"\$PSQL" -d template1 -tAc \
"SELECT 1 FROM pg_tablespace WHERE spcname='${POSTGRES_DB}_data'" | grep -q 1 || \
"\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
"CREATE TABLESPACE ${POSTGRES_DB}_data OWNER protheus LOCATION '/postgres/pg_data/${POSTGRES_DB}/data';"

"\$PSQL" -d template1 -tAc \
"SELECT 1 FROM pg_tablespace WHERE spcname='${POSTGRES_DB}_index'" | grep -q 1 || \
"\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
"CREATE TABLESPACE ${POSTGRES_DB}_index OWNER protheus LOCATION '/postgres/pg_data/${POSTGRES_DB}/index';"

DB_READY=\$("\$PSQL" -d template1 -tAc \
"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}' AND dattablespace = (SELECT oid FROM pg_tablespace WHERE spcname='${POSTGRES_DB}_data')")

if [[ "\$DB_READY" == "1" ]]; then
    echo "Banco ja configurado."
else
    "\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
    "DROP DATABASE IF EXISTS ${POSTGRES_DB};"

    "\$PSQL" -d template1 -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE ${POSTGRES_DB} WITH OWNER protheus TEMPLATE template0 ENCODING 'WIN1252' LC_COLLATE 'C' LC_CTYPE 'C' TABLESPACE ${POSTGRES_DB}_data CONNECTION LIMIT -1;"
fi
EOF

docker exec -u postgres "$DB_CONTAINER" \
    bash /shared/setup_db.sh \
    || die "Erro na configuracao do banco."

rm -f "$SHARED_DIR/setup_db.sh"

show_success "Banco de dados configurado."

# --------------------------------------------------------
# Localizar dump
# --------------------------------------------------------

show_step "Localizando arquivo de backup..."

DUMP_FILE=""
DUMP_TYPE=""

if [[ -f "$PROJECT_ROOT/db/backups/custom_dump.tar" ]]; then

    DUMP_FILE="/backups/custom_dump.tar"
    DUMP_TYPE="customizado"

elif [[ -f "$SHARED_DIR/dump_protheus.tar" ]]; then

    DUMP_FILE="/shared/dump_protheus.tar"
    DUMP_TYPE="padrao"

fi

if [[ -z "$DUMP_FILE" ]]; then
    show_warning "Nenhum dump encontrado. Base permanecera vazia."
else

    printf "     Dump selecionado: %s\n" "$DUMP_FILE"

    # ----------------------------------------------------
    # Validar catalogo do backup
    # ----------------------------------------------------

    show_step "Validando estrutura do arquivo TAR..."

    docker exec -u postgres "$DB_CONTAINER" \
        "$PG_RESTORE" --list "$DUMP_FILE" \
        > "$SHARED_DIR/restore_toc.list" \
        || die "Dump invalido ou incompativel."

    TOC_COUNT=$(grep -cE '^[0-9]+;' "$SHARED_DIR/restore_toc.list" || true)

    [[ "$TOC_COUNT" -gt 0 ]] \
        || die "Dump sem objetos restauraveis."

    printf "     Objetos identificados no backup: %s\n" "$TOC_COUNT"

    show_success "Catalogo do backup validado."

    # ----------------------------------------------------
    # Restaurar estrutura e dados
    # ----------------------------------------------------

    show_step "Restaurando banco com PostgreSQL 16..."

    RESTORE_LOG="$SHARED_DIR/restore_protheus.log"

    if docker exec -u postgres "$DB_CONTAINER" \
        "$PG_RESTORE" \
        --verbose \
        --exit-on-error \
        --single-transaction \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        -U postgres \
        -d "$POSTGRES_DB" \
        "$DUMP_FILE" \
        2>&1 | tee "$RESTORE_LOG"; then

        show_success "Restauracao executada sem erros."
        
        # ----------------------------------------------------
        # CORRECAO: Ajustar Propriedade dos Objetos para o usuario protheus
        # ----------------------------------------------------
        show_step "Ajustando propriedade dos objetos para o usuario protheus..."
        docker exec -i -u postgres "$DB_CONTAINER" "$PSQL" -d "$POSTGRES_DB" << 'EOF'
        DO $$ 
        DECLARE 
            r RECORD; 
        BEGIN 
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP 
                EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' OWNER TO protheus;'; 
            END LOOP; 
            FOR r IN (SELECT sequencename FROM pg_sequences WHERE schemaname = 'public') LOOP 
                EXECUTE 'ALTER SEQUENCE public.' || quote_ident(r.sequencename) || ' OWNER TO protheus;'; 
            END LOOP;
            FOR r IN (SELECT viewname FROM pg_views WHERE schemaname = 'public') LOOP 
                EXECUTE 'ALTER VIEW public.' || quote_ident(r.viewname) || ' OWNER TO protheus;'; 
            END LOOP;
        END $$;
EOF
        show_success "Propriedade dos objetos ajustada com sucesso."

    else
        show_fail "Falha durante a restauracao."
        show_warning "Consulte: $RESTORE_LOG"
        exit 1
    fi

    # ----------------------------------------------------
    # Validar estrutura restaurada
    # ----------------------------------------------------

    show_step "Validando estrutura recuperada..."

    TABLE_COUNT=$(
        docker exec -u postgres "$DB_CONTAINER" \
        "$PSQL" -U postgres -d "$POSTGRES_DB" -Atc "
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            AND table_type = 'BASE TABLE';
        "
    ) || die "Falha ao verificar tabelas."

    SEQUENCE_COUNT=$(
        docker exec -u postgres "$DB_CONTAINER" \
        "$PSQL" -U postgres -d "$POSTGRES_DB" -Atc "
            SELECT COUNT(*)
            FROM information_schema.sequences
            WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema');
        "
    ) || die "Falha ao verificar sequences."

    FUNCTION_COUNT=$(
        docker exec -u postgres "$DB_CONTAINER" \
        "$PSQL" -U postgres -d "$POSTGRES_DB" -Atc "
            SELECT COUNT(*)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema');
        "
    ) || die "Falha ao verificar funcoes."

    INDEX_COUNT=$(
        docker exec -u postgres "$DB_CONTAINER" \
        "$PSQL" -U postgres -d "$POSTGRES_DB" -Atc "
            SELECT COUNT(*)
            FROM pg_indexes
            WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
        "
    ) || die "Falha ao verificar indices."

    printf "\n"
    printf "     ========================================\n"
    printf "     VALIDACAO DO BANCO RESTAURADO\n"
    printf "     ========================================\n"
    printf "     Tabelas:     %s\n" "$TABLE_COUNT"
    printf "     Sequences:   %s\n" "$SEQUENCE_COUNT"
    printf "     Funcoes:     %s\n" "$FUNCTION_COUNT"
    printf "     Indices:     %s\n" "$INDEX_COUNT"
    printf "     ========================================\n\n"

    # ----------------------------------------------------
    # Exportar estrutura restaurada para auditoria
    # ----------------------------------------------------

    show_step "Gerando relatorio da estrutura recuperada..."

    docker exec -u postgres "$DB_CONTAINER" \
        "$PG_DUMP" \
        -U postgres \
        -d "$POSTGRES_DB" \
        --schema-only \
        --no-owner \
        --no-privileges \
        > "$SHARED_DIR/estrutura_restaurada.sql" \
        || die "Falha ao exportar estrutura restaurada."

    [[ -s "$SHARED_DIR/estrutura_restaurada.sql" ]] \
        || die "Relatorio de estrutura vazio."

    show_success "Estrutura exportada para shared/estrutura_restaurada.sql"

    show_success "Dump $DUMP_TYPE restaurado e validado."

fi


# ========================================================
# 7. LICENSE SERVER
# ========================================================
show_step "Configurando License Server (Nativo)..."
docker exec "$LICENSE_CONTAINER" mkdir -p "$LICENSE_TARGET"
docker exec "$LICENSE_CONTAINER" tar -xf "/shared/$LICENSE_ARCHIVE" -C "$LICENSE_TARGET"

# GARANTIR PERMISSÃO LOCAL (777)
docker exec "$LICENSE_CONTAINER" chmod -R 777 "$LICENSE_TARGET"

docker exec "$LICENSE_CONTAINER" mkdir -p /lib/x86_64-linux-gnu
docker exec "$LICENSE_CONTAINER" cp /totvs/licenseserver/bin/appserver/libbtmonitor.so /lib/x86_64-linux-gnu/ 2>/dev/null || true

cat << EOF > "$PROJECT_ROOT/docker/licenseserver/appserver.ini"
[ENVIRONMENT]
SourcePath=/totvs/licenseserver/data/apo
RootPath=/totvs/licenseserver/data/
StartPath=/system/
RpoDb=SQLite
RpoLanguage=PORTUGUESE
RpoVersion=120
LocalFiles=SQLite
DBDataBase=SQLite
DBAlias=SYSTEM
DBServer=localhost
startSysInDB=1
TOPMemoMega=1
RPOCustom=/totvs/licenseserver/bin/appserver/custom.rpo

[DRIVERS]
Active=TCP
MultiProtocolPortSecure=0
MultiProtocolPort=0

[TCP]
TYPE=TCPIP
Port=2234

[LICENSESERVER]
Enable=1
Port=$LICENSESERVER_PORT
ShowStatus=0
EnableNumber=1
LicenseFile=lsinitialize.inf
IPCGOTIMEOUT=45000
IPCRETURNTIMEOUT=90000
NUMBERVAL=1
AUTOSAVENUMBER=1
STATELESSREUSECONN=60

[LICENSECLIENT]
Server=LOCALHOST
Port=$LICENSESERVER_PORT
Enable=1
EOF

docker exec "$LICENSE_CONTAINER" systemctl daemon-reload
docker exec "$LICENSE_CONTAINER" systemctl enable license-server
docker exec "$LICENSE_CONTAINER" systemctl start license-server
sleep 10
show_success "License Server rodando."

# ========================================================
# 8. DBACCESS
# ========================================================
show_step "Configurando DBAccess e ODBC..."
docker exec "$DBACCESS_CONTAINER" mkdir -p "$DBACCESS_TARGET"
docker exec "$DBACCESS_CONTAINER" tar -xf "/shared/$DBACCESS_ARCHIVE" -C "$DBACCESS_TARGET"

# GARANTIR PERMISSÃO LOCAL (777)
docker exec "$DBACCESS_CONTAINER" chmod -R 777 "$DBACCESS_TARGET"

docker exec "$DBACCESS_CONTAINER" bash -c "command -v dnf >/dev/null && dnf install -y unixODBC postgresql-odbc postgresql >/dev/null 2>&1 || microdnf install -y unixODBC postgresql-odbc postgresql >/dev/null 2>&1"

cat << EOF > "$PROJECT_ROOT/config/dbaccess/odbc.ini"
[${POSTGRES_DB}]
Description=PostgreSQL
Driver=PostgreSQL ANSI
Trace=Yes
TraceFile=/tmp/psqlodbc_${POSTGRES_DB}.log
Servername=tp-db
Database=${POSTGRES_DB}
UserName=protheus
Password=${POSTGRES_PASSWORD}
Port=5432
ReadOnly=No
RowVersioning=No
ShowSystemTables=No
ShowOidColumn=No
FakeOidIndex=No
ConnSettings=
EOF

cat << EOF > "$PROJECT_ROOT/docker/dbaccess/dbaccess.ini"
[General]
InstallPath=/totvs/protheus/bin/dbaccess
ODBC30=1
Port=$DBACCESS_PORT
ThreadInfo=0
LogFull=0
GlbPRofiler=0
ThreadMin=200
ThreadMax=10000
ThreadInc=100
ConsoleMaxSize=100000000
maxStringSize=100
LicenseServer=
LicensePort=0

[POSTGRES]
environments=$POSTGRES_DB
clientlibrary=TO_BE_REPLACED_BY_BASH
CodePage=WIN1252

[POSTGRES/$POSTGRES_DB]
user=protheus
password=$POSTGRES_PASSWORD
TableSpace=${POSTGRES_DB}_data
IndexSpace=${POSTGRES_DB}_index
Disable=0
EOF

docker exec "$DBACCESS_CONTAINER" cp /totvs/config/odbcinst.ini /etc/odbcinst.ini
docker exec "$DBACCESS_CONTAINER" cp /totvs/config/odbc.ini /etc/odbc.ini
docker exec "$DBACCESS_CONTAINER" odbcinst -i -d -f /etc/odbcinst.ini >/dev/null
docker exec "$DBACCESS_CONTAINER" odbcinst -i -s -l -f /etc/odbc.ini >/dev/null

cat << 'EOF' > "$SHARED_DIR/fix_odbc.sh"
#!/bin/bash
INI_FILE="/totvs/protheus/bin/dbaccess/multi/dbaccess.ini"
ODBC_PATH=$(find /usr -name "psqlodbc.so" | head -n 1)
[ -z "$ODBC_PATH" ] && ODBC_PATH=$(find /usr -name "psqlodbcw.so" | head -n 1)
if [ -n "$ODBC_PATH" ]; then
    sed "s|^clientlibrary=.*|clientlibrary=$ODBC_PATH|g" "$INI_FILE" > /tmp/dbaccess.ini.tmp
    cat /tmp/dbaccess.ini.tmp > "$INI_FILE"
    rm -f /tmp/dbaccess.ini.tmp
fi
EOF
docker exec "$DBACCESS_CONTAINER" bash /shared/fix_odbc.sh
rm -f "$SHARED_DIR/fix_odbc.sh"

docker exec "$DBACCESS_CONTAINER" isql -v "$POSTGRES_DB" >/dev/null || die "Erro na conexao ISQL nativa."
docker exec "$DBACCESS_CONTAINER" systemctl daemon-reload
docker exec "$DBACCESS_CONTAINER" systemctl enable dbaccess
docker exec "$DBACCESS_CONTAINER" systemctl start dbaccess
sleep 3
show_success "DBAccess rodando."

# ========================================================
# 9. APPSERVER
# ========================================================
show_step "Configurando AppServer e RPO..."
docker exec "$APPSERVER_CONTAINER" mkdir -p "$APPSERVER_TARGET" "$APO_TARGET" /totvs/protheus/bin/log
docker exec "$APPSERVER_CONTAINER" tar -xf "/shared/$APPSERVER_ARCHIVE" -C "$APPSERVER_TARGET"
docker exec "$APPSERVER_CONTAINER" cp "/shared/tttm120.rpo" "$APO_TARGET/"
docker exec "$APPSERVER_CONTAINER" cp "/shared/custom.rpo" "$APO_TARGET/"

# GARANTIR PERMISSÃO LOCAL (777)
docker exec "$APPSERVER_CONTAINER" chmod -R 777 "$APPSERVER_TARGET"

docker exec "$APPSERVER_CONTAINER" bash -c "command -v unzip >/dev/null || dnf install -y unzip >/dev/null 2>&1 || microdnf install -y unzip >/dev/null 2>&1"

# Extrair complementos
docker exec "$APPSERVER_CONTAINER" bash -c "[ -f /shared/HELPS.ZIP ] && unzip -qo /shared/HELPS.ZIP -d /totvs/protheus_data/systemload || true"
docker exec "$APPSERVER_CONTAINER" bash -c "[ -f /shared/DICIONARIOS.ZIP ] && unzip -qo /shared/DICIONARIOS.ZIP -d /totvs/protheus_data/systemload || true"
docker exec "$APPSERVER_CONTAINER" bash -c "[ -f /shared/MENUS.ZIP ] && unzip -qo /shared/MENUS.ZIP -d /totvs/protheus_data/system || true"
docker exec "$APPSERVER_CONTAINER" bash -c "[ -f /shared/WEBAPP.TAR ] && tar -xf /shared/WEBAPP.TAR -C /totvs/protheus/bin/appserver || true"
docker exec "$APPSERVER_CONTAINER" bash -c "[ -f /shared/WEBAPP.ZIP ] && unzip -qo /shared/WEBAPP.ZIP -d /totvs/protheus/bin/appserver || true"

cat << EOF > "$PROJECT_ROOT/docker/appserver/appserver.ini"
[environment]
SourcePath=/totvs/protheus/bin/apo
RPOCustom=/totvs/protheus/bin/apo/custom.rpo
RootPath=/totvs/protheus_data
StartPath=/system/
RpoDb=top
RpoLanguage=Portuguese
RpoVersion=120
LocalFiles=CTREE
Trace=0
localdbextension=.dtc
TopMemoMega=1
PictFormat=DEFAULT
RegionalLanguage=BRA
SpecialKey=environment
StartSysInDB=1

[DBAccess]
DataBase=postgres
Server=$DBACCESS_CONTAINER
ALIAS=$POSTGRES_DB
PROTHEUSONLY=0

[General]
CONSOLELOG=1
CONSOLEFILE=/totvs/protheus/bin/appserver/appserver.log
InstallPath=/totvs/
CanAcceptFSRemote=1
App_Environment=environment

[Drivers]
ACTIVE=TCP
MultiProtocolPort=1

[TCP]
TYPE=TCPIP
PORT=$APPSERVER_PORT

[LICENSECLIENT]
SERVER=$LICENSE_CONTAINER
PORT=$LICENSESERVER_PORT

[WEBAPP]
PORT=1235
EOF

docker exec "$APPSERVER_CONTAINER" systemctl daemon-reload
docker exec "$APPSERVER_CONTAINER" systemctl enable appserver
docker exec "$APPSERVER_CONTAINER" systemctl start appserver
sleep 3
show_success "AppServer configurado."

# ========================================================
# 10. SMART VIEW
# ========================================================
show_step "Configurando Smart View..."
docker exec "$SMARTVIEW_CONTAINER" bash -c "dnf install -y unzip libicu krb5-libs zlib openssl-libs >/dev/null 2>&1 || true"
docker exec "$SMARTVIEW_CONTAINER" mkdir -p "$SMARTVIEW_TARGET"
docker exec "$SMARTVIEW_CONTAINER" bash -c "unzip -qo /shared/$SMARTVIEW_ARCHIVE -d $SMARTVIEW_TARGET || true"
docker exec "$SMARTVIEW_CONTAINER" bash -c "chmod +x $SMARTVIEW_TARGET/TReports.Agent || true"
docker exec "$SMARTVIEW_CONTAINER" systemctl daemon-reload
docker exec "$SMARTVIEW_CONTAINER" systemctl enable smart-view-agent
docker exec "$SMARTVIEW_CONTAINER" systemctl start smart-view-agent
show_success "Smart View rodando."

# ========================================================
# CONCLUSAO
# ========================================================
show_header "STATUS FINAL"
docker compose -f "$COMPOSE_FILE" ps || true
printf "\n"

DASHBOARD_URL="http://localhost:3000"
show_step "Aguardando Dashboard Web..."
READY=0
for i in {1..15}; do
    if command_exists curl && curl --silent --fail "$DASHBOARD_URL" >/dev/null 2>&1; then READY=1; break; fi
    sleep 1
done

if [[ "$READY" -eq 1 ]]; then
    show_success "Dashboard disponível em $DASHBOARD_URL"
    case "$(uname -s)" in
        Darwin) command_exists open && open "$DASHBOARD_URL" >/dev/null 2>&1 || true ;;
        Linux) command_exists xdg-open && xdg-open "$DASHBOARD_URL" >/dev/null 2>&1 & ;;
    esac
else
    show_warning "Dashboard offline ou indisponivel no momento."
fi

show_header "PROCESSO CONCLUIDO COM SUCESSO"