
#!/usr/bin/env bash

set -Eeuo pipefail

# ========================================================
# TOTVS PROTHEUS - AMBIENTE DOCKER
# Compatibilidade: GNU/Linux e macOS
# Requisito: Bash 3.2+
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

DBACCESS_CONTAINER="${DBACCESS_CONTAINER:-tp-dbaccess}"
APPSERVER_CONTAINER="${APPSERVER_CONTAINER:-tp-appserver}"

DBACCESS_ARCHIVE="${DBACCESS_ARCHIVE:-DBACCESS.TAR}"
APPSERVER_ARCHIVE="${APPSERVER_ARCHIVE:-APPSERVER.TAR}"
RPO_ARCHIVE="${RPO_ARCHIVE:-REPOSITORIO.RPO}"

DBACCESS_TARGET="/totvs/protheus/bin/dbaccess"
APPSERVER_TARGET="/totvs/protheus/bin/appserver"
APO_TARGET="/totvs/protheus/bin/apo"

# ========================================================
# INTERFACE
# ========================================================

show_header() {
    printf '\n========================================================\n'
    printf '  %s\n' "$1"
    printf '========================================================\n\n'
}

show_step() {
    printf '\033[1;33m [+] %s\033[0m\n' "$1"
}

show_success() {
    printf '\033[1;32m [OK] %s\033[0m\n' "$1"
}

show_fail() {
    printf '\033[1;31m [ERRO] %s\033[0m\n' "$1" >&2
}

show_warning() {
    printf '\033[1;33m [!] %s\033[0m\n' "$1"
}

die() {
    show_fail "$1"
    exit 1
}

# ========================================================
# TRATAMENTO DE ERROS
# ========================================================

on_error() {
    local exit_code=$?
    local line="${1:-desconhecida}"

    show_fail "Erro na linha ${line}. Codigo de saida: ${exit_code}."
    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

# ========================================================
# VERIFICAR COMANDOS
# ========================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" ||
        die "Comando '$1' nao encontrado. Instale-o e tente novamente."
}

# ========================================================
# LER CONFIGURACAO JSON
# Usa Python 3, sem dependencias externas.
# ========================================================

read_json_field() {
    local json_file="$1"
    local field="$2"

    python3 - "$json_file" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]

try:
    with open(path, "r", encoding="utf-8-sig") as f:
        data = json.load(f)

    value = data.get(field, "")

    if not isinstance(value, str):
        value = str(value) if value is not None else ""

    print(value.strip())
except Exception as exc:
    print(f"Erro ao ler JSON: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

# ========================================================
# VALIDAR HASH SHA-256
# ========================================================

calculate_sha256() {
    local file="$1"

    if command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        die "Nenhuma ferramenta SHA-256 encontrada (sha256sum, shasum ou openssl)."
    fi
}

# ========================================================
# DOWNLOAD COM BARRA DE PROGRESSO
# ========================================================

download_file() {
    local url="$1"
    local destination="$2"
    local temp_file="${destination}.part"

    show_step "Baixando arquivo de dependencias..."

    rm -f "$temp_file"

    if command_exists curl; then
        if ! curl \
            --fail \
            --location \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 30 \
            --progress-bar \
            --output "$temp_file" \
            "$url"; then
            rm -f "$temp_file"
            die "Falha ao baixar o arquivo usando curl."
        fi
    elif command_exists wget; then
        if ! wget \
            --tries=3 \
            --timeout=30 \
            --show-progress \
            --progress=bar:force \
            --output-document="$temp_file" \
            "$url"; then
            rm -f "$temp_file"
            die "Falha ao baixar o arquivo usando wget."
        fi
    else
        die "Instale curl ou wget para permitir o download."
    fi

    [[ -s "$temp_file" ]] ||
        die "O arquivo baixado esta vazio."

    mv -f "$temp_file" "$destination"

    show_success "Download concluido."
}

# ========================================================
# EXECUTAR COMANDO DOCKER COM VALIDACAO
# ========================================================

docker_exec_checked() {
    local container="$1"
    shift

    if ! docker exec "$container" "$@"; then
        die "Falha ao executar comando no container '$container': $*"
    fi
}

# ========================================================
# ABERTURA DO NAVEGADOR
# ========================================================

open_browser() {
    local url="$1"

    case "$(uname -s)" in
        Darwin)
            if command_exists open; then
                open "$url" >/dev/null 2>&1 || true
            fi
            ;;
        Linux)
            if command_exists xdg-open; then
                xdg-open "$url" >/dev/null 2>&1 &
            fi
            ;;
    esac
}

# ========================================================
# 1. VALIDAR AMBIENTE E CONFIGURACAO
# ========================================================

show_header "TOTVS PROTHEUS - AMBIENTE DOCKER"

show_step "Verificando sistema operacional..."

case "$(uname -s)" in
    Linux|Darwin)
        show_success "Sistema operacional compativel: $(uname -s)."
        ;;
    *)
        die "Este script suporta GNU/Linux e macOS."
        ;;
esac

require_command python3
require_command docker
require_command tar
require_command awk

show_step "Validando arquivo de configuracao..."

[[ -f "$CONFIG_FILE" ]] ||
    die "Arquivo de configuracao nao encontrado: $CONFIG_FILE"

DOWNLOAD_URL="$(read_json_field "$CONFIG_FILE" url)"
EXPECTED_HASH="$(read_json_field "$CONFIG_FILE" sha256)"

[[ -n "$DOWNLOAD_URL" ]] ||
    die "O campo 'url' esta ausente em config/download.json."

[[ "$DOWNLOAD_URL" =~ ^https?:// ]] ||
    die "A URL deve comecar com http:// ou https://."

[[ "$EXPECTED_HASH" =~ ^[a-fA-F0-9]{64}$ ]] ||
    die "O campo 'sha256' deve conter exatamente 64 caracteres hexadecimais."

show_success "Arquivo de configuracao validado."

# ========================================================
# 2. CRIAR DIRETORIO COMPARTILHADO
# ========================================================

show_step "Preparando diretorio compartilhado..."

mkdir -p "$SHARED_DIR"

FULL_ARCHIVE="$SHARED_DIR/full.tar"

# ========================================================
# 3. BAIXAR DEPENDENCIAS
# ========================================================

download_file "$DOWNLOAD_URL" "$FULL_ARCHIVE"

# ========================================================
# 4. VALIDAR HASH SHA-256
# ========================================================

show_step "Validando hash SHA-256..."

ACTUAL_HASH="$(calculate_sha256 "$FULL_ARCHIVE")"

if [[ "${ACTUAL_HASH,,}" != "${EXPECTED_HASH,,}" ]]; then
    show_fail "O hash SHA-256 do arquivo nao confere."
    printf '     Esperado: %s\n' "$EXPECTED_HASH" >&2
    printf '     Recebido: %s\n' "$ACTUAL_HASH" >&2

    rm -f "$FULL_ARCHIVE"
    exit 1
fi

show_success "Hash SHA-256 validado com sucesso."

# ========================================================
# 5. EXTRAIR ARQUIVO TAR
# ========================================================

show_step "Extraindo dependencias em '$SHARED_DIR'..."

if ! tar -tf "$FULL_ARCHIVE" >/dev/null; then
    die "O arquivo baixado nao e um TAR valido."
fi

if ! tar -xf "$FULL_ARCHIVE" -C "$SHARED_DIR"; then
    die "Falha ao extrair o arquivo TAR."
fi

rm -f "$FULL_ARCHIVE"

show_success "Dependencias extraidas."

# ========================================================
# 6. CRIAR ESTRUTURA DE DIRETORIOS E ARQUIVOS
# ========================================================

show_step "Criando estrutura de diretorios..."

DIRECTORIES=(
    "docker/appserver"
    "docker/appserver/apo"
    "docker/dbaccess"
    "docker/licenseserver"
    "protheus_data/system"
    "protheus_data/data"
    "db/init"
    "db/backups"
)

for dir in "${DIRECTORIES[@]}"; do
    mkdir -p "$PROJECT_ROOT/$dir"
done

FILES=(
    "docker/appserver/appserver.ini"
    "docker/dbaccess/dbaccess.ini"
    "docker/licenseserver/appserver.ini"
)

for file in "${FILES[@]}"; do
    if [[ ! -e "$PROJECT_ROOT/$file" ]]; then
        touch "$PROJECT_ROOT/$file"
    fi
done

DOCKERIGNORE="$PROJECT_ROOT/.dockerignore"

if [[ ! -f "$DOCKERIGNORE" ]]; then
    cat > "$DOCKERIGNORE" <<'EOF'
shared/
*.tar
.git/
.env
EOF
fi

show_success "Estrutura de diretorios pronta."

# ========================================================
# 7. CRIAR ARQUIVOS DE AMBIENTE
# Nao sobrescreve configuracoes existentes.
# ========================================================

show_step "Verificando arquivos de ambiente..."

create_env_file() {
    local destination="$1"

    if [[ ! -f "$destination" ]]; then
        cat > "$destination" <<'EOF'
POSTGRES_DB=protheus
POSTGRES_USER=postgres
POSTGRES_PASSWORD=protheus_pwd
POSTGRES_PORT=5432
APPSERVER_PORT=1234
DBACCESS_PORT=7890
LICENSESERVER_PORT=5555
SHARED_DIR=./shared
EOF
        show_success "Arquivo criado: $destination"
    else
        show_success "Arquivo existente preservado: $destination"
    fi
}

create_env_file "$ENV_EXAMPLE_FILE"
create_env_file "$ENV_FILE"

# ========================================================
# 8. VALIDAR DOCKER E DOCKER COMPOSE
# ========================================================

show_step "Verificando Docker..."

if ! docker info >/dev/null 2>&1; then
    die "Docker nao esta acessivel. Inicie o Docker Engine ou Docker Desktop."
fi

if ! docker compose version >/dev/null 2>&1; then
    die "O plugin Docker Compose nao esta disponivel."
fi

show_success "Docker e Docker Compose estao disponiveis."

# ========================================================
# 9. LOCALIZAR ARQUIVO DOCKER COMPOSE
# ========================================================

show_step "Localizando configuracao Docker Compose..."

COMPOSE_CANDIDATES=(
    "docker-compose.yml"
    "compose.yaml"
    "compose.yml"
    "docker-compose.yaml"
)

COMPOSE_FILE=""

for candidate in "${COMPOSE_CANDIDATES[@]}"; do
    if [[ -f "$PROJECT_ROOT/$candidate" ]]; then
        COMPOSE_FILE="$PROJECT_ROOT/$candidate"
        break
    fi
done

[[ -n "$COMPOSE_FILE" ]] ||
    die "Nenhum arquivo Docker Compose foi encontrado na raiz do projeto."

if ! docker compose -f "$COMPOSE_FILE" config --quiet; then
    die "A configuracao Docker Compose possui erros. Verifique o YAML e o .env."
fi

show_success "Configuracao Docker Compose validada."

# ========================================================
# 10. BAIXAR IMAGENS DOCKER
# ========================================================

show_step "Atualizando imagens Docker..."

if ! docker pull postgres:16; then
    die "Falha ao baixar a imagem postgres:16."
fi

if ! docker pull oraclelinux:10; then
    die "Falha ao baixar a imagem oraclelinux:10."
fi

show_success "Imagens atualizadas."

# ========================================================
# 11. INICIALIZAR CONTAINERS
# ========================================================

show_step "Inicializando containers via Docker Compose..."

if ! docker compose -f "$COMPOSE_FILE" up -d; then
    docker compose -f "$COMPOSE_FILE" logs --tail=100 || true
    die "Falha ao inicializar os containers."
fi

show_success "Ambiente inicializado."

# ========================================================
# 12. VALIDAR ARQUIVOS DE BINARIOS
# ========================================================

show_step "Validando arquivos do DBAccess e AppServer..."

DBACCESS_ARCHIVE_PATH="$SHARED_DIR/$DBACCESS_ARCHIVE"
APPSERVER_ARCHIVE_PATH="$SHARED_DIR/$APPSERVER_ARCHIVE"
RPO_ARCHIVE_PATH="$SHARED_DIR/$RPO_ARCHIVE"

for archive in \
    "$DBACCESS_ARCHIVE_PATH" \
    "$APPSERVER_ARCHIVE_PATH" \
    "$RPO_ARCHIVE_PATH"; do

    if [[ ! -f "$archive" ]]; then
        die "Arquivo necessario nao encontrado: $archive"
    fi
done

show_success "Arquivos de binarios encontrados."

# ========================================================
# 13. CONFIGURAR BINARIOS DO DBACCESS
# ========================================================

show_step "Configurando binarios do DBAccess..."

docker_exec_checked "$DBACCESS_CONTAINER" \
    mkdir -p "$DBACCESS_TARGET"

docker_exec_checked "$DBACCESS_CONTAINER" \
    tar -xf "/shared/$DBACCESS_ARCHIVE" -C "$DBACCESS_TARGET"

docker_exec_checked "$DBACCESS_CONTAINER" \
    chmod -R +x "$DBACCESS_TARGET"

show_success "Binarios do DBAccess configurados."

# ========================================================
# 14. CONFIGURAR BINARIOS E RPO DO APPSERVER
# ========================================================

show_step "Configurando binarios e RPO do AppServer..."

docker_exec_checked "$APPSERVER_CONTAINER" \
    mkdir -p "$APPSERVER_TARGET" "$APO_TARGET"

docker_exec_checked "$APPSERVER_CONTAINER" \
    tar -xf "/shared/$APPSERVER_ARCHIVE" -C "$APPSERVER_TARGET"

docker_exec_checked "$APPSERVER_CONTAINER" \
    cp "/shared/$RPO_ARCHIVE" "$APO_TARGET/tttm120.rpo"

docker_exec_checked "$APPSERVER_CONTAINER" \
    touch "$APO_TARGET/custom.rpo"

docker_exec_checked "$APPSERVER_CONTAINER" \
    chmod -R +x "$APPSERVER_TARGET"

show_success "Binarios e RPOs do AppServer configurados."

# ========================================================
# 15. STATUS DOS CONTAINERS
# ========================================================

show_header "STATUS DOS CONTAINERS"

if ! docker compose -f "$COMPOSE_FILE" ps; then
    die "Nao foi possivel consultar o status dos containers."
fi

# ========================================================
# 16. INICIALIZAR DASHBOARD WEB
# ========================================================

show_header "INICIALIZANDO DASHBOARD DE GERENCIAMENTO"

DASHBOARD_URL="http://localhost:3000"

show_step "Aguardando resposta do Dashboard Web..."

# Aguarda ate 15 segundos para o container subir e responder
READY=0
for i in {1..15}; do
    if command_exists curl && curl --silent --fail "$DASHBOARD_URL" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [[ "$READY" -eq 1 ]]; then
    show_success "Dashboard disponível em $DASHBOARD_URL"
    open_browser "$DASHBOARD_URL"
else
    show_warning "O dashboard nao respondeu a tempo em $DASHBOARD_URL."
    show_warning "Verifique os logs do container com: docker compose logs tp-dashboard"
fi

# ========================================================
# CONCLUSAO
# ========================================================

show_header "PROCESSO CONCLUIDO"
show_success "Script finalizado."