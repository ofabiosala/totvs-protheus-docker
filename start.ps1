[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ========================================================
# CONFIGURACAO INICIAL
# ========================================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
}

Set-Location -LiteralPath $ProjectRoot

$SharedDir = Join-Path $ProjectRoot "shared"
$ConfigFile = Join-Path $ProjectRoot "config/download.json"
$EnvFile = Join-Path $ProjectRoot ".env"
$EnvExampleFile = Join-Path $ProjectRoot ".env.example"

# Containers
$DbContainer = "tp-db"
$LicenseServerContainer = "tp-licenseserver"
$DbAccessContainer = "tp-dbaccess"
$AppServerContainer = "tp-appserver"
$SmartViewContainer = "tp-smartview"

# Arquivos
$LicenseArchive = "LICENSE.TAR"
$DbAccessArchive = "DBACCESS.TAR"
$AppServerArchive = "APPSERVER.TAR"
$RpoArchive = "REPOSITORIO.RPO"
$SmartViewArchive = "SMART_VIEW.zip"

# Diretórios Alvo Internos
$LicenseServerTarget = "/totvs/licenseserver"
$DbAccessTarget = "/totvs/protheus/bin/dbaccess"
$AppServerTarget = "/totvs/protheus/bin/appserver"
$ApoTarget = "/totvs/protheus/bin/apo"
$SmartViewTarget = "/usr/sbin/smart-view"

# ========================================================
# INTERFACE
# ========================================================

function Show-Header {
    param([string]$Title)
    Write-Host "`n========================================================" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor DarkGray
}

function Show-Step {
    param([string]$Message)
    Write-Host " [+] $Message" -ForegroundColor Yellow
}

function Show-Success {
    param([string]$Message)
    Write-Host " [OK] $Message" -ForegroundColor Green
}

function Show-Fail {
    param([string]$Message)
    Write-Host " [ERRO] $Message" -ForegroundColor Red
}

function Show-Warning {
    param([string]$Message)
    Write-Host " [!] $Message" -ForegroundColor DarkYellow
}

function Invoke-Die {
    param([string]$Message)
    Show-Fail $Message
    exit 1
}

# ========================================================
# VERIFICAR COMANDOS
# ========================================================

function Test-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    return $null -ne (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
}

# ========================================================
# DOWNLOAD COM BARRA DE PROGRESSO
# ========================================================

function Download-FileWithBar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [int]$BarWidth = 25
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    $httpClient = New-Object System.Net.Http.HttpClient
    $response = $null
    $readStream = $null
    $fileStream = $null

    try {
        $response = $httpClient.GetAsync(
            $Url,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        $null = $response.EnsureSuccessStatusCode()
        $totalBytes = $response.Content.Headers.ContentLength

        $readStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($DestinationPath)

        $buffer = New-Object byte[] 1048576
        $totalRead = [long]0
        $lastPercent = -1

        while (($bytesRead = $readStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead

            if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                $percent = [int][math]::Floor(($totalRead / $totalBytes) * 100)

                if ($percent -ne $lastPercent) {
                    $lastPercent = $percent
                    $filled = [int][math]::Floor(($percent / 100) * $BarWidth)
                    $empty = $BarWidth - $filled
                    $bar = ("#" * $filled) + ("_" * $empty)

                    $curMB = [math]::Round($totalRead / 1MB, 1)
                    $allMB = [math]::Round($totalBytes / 1MB, 1)

                    Write-Host (
                        "`r     [{0}] {1}% ({2} / {3} MB)" -f
                        $bar, $percent, $curMB, $allMB
                    ) -NoNewline -ForegroundColor Cyan
                }
            }
            else {
                $curMB = [math]::Round($totalRead / 1MB, 1)
                Write-Host ("`r     Baixado: {0} MB..." -f $curMB) -NoNewline -ForegroundColor Cyan
            }
        }

        if ($null -ne $totalBytes -and $totalBytes -gt 0 -and $totalRead -ne $totalBytes) {
            throw "Download incompleto. Esperado: $totalBytes bytes. Recebido: $totalRead bytes."
        }

        Write-Host ""
    }
    catch {
        Write-Host ""
        throw
    }
    finally {
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if ($null -ne $readStream) { $readStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $httpClient.Dispose()
    }
}

# ========================================================
# EXECUCAO
# ========================================================

Clear-Host
Show-Header "TOTVS PROTHEUS - AMBIENTE DOCKER"

# ========================================================
# 1. VALIDAR AMBIENTE E CONFIGURACAO
# ========================================================

Show-Step "Validando arquivo de configuracao..."

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    Invoke-Die "Arquivo de configuracao '$ConfigFile' nao encontrado."
}

try {
    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Invoke-Die "Nao foi possivel ler o JSON: $($_.Exception.Message)"
}

$downloadUrl = [string]$config.url
$expectedHash = ([string]$config.sha256).Trim()

if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
    Invoke-Die "O campo 'url' esta ausente em config/download.json."
}

if ($downloadUrl -notmatch '^https?://') {
    Invoke-Die "A URL de download deve comecar com http:// ou https://."
}

if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') {
    Invoke-Die "O campo 'sha256' deve conter exatamente 64 caracteres hexadecimais."
}

Show-Success "Arquivo de configuracao validado."

# ========================================================
# 2. CRIAR DIRETORIO COMPARTILHADO
# ========================================================

Show-Step "Preparando diretorio compartilhado..."

if (-not (Test-Path -LiteralPath $SharedDir -PathType Container)) {
    New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
}

$tarFile = Join-Path $SharedDir "full.tar"

# ========================================================
# 3. BAIXAR DEPENDENCIAS
# ========================================================

Show-Step "Baixando dependencias..."

try {
    Download-FileWithBar -Url $downloadUrl -DestinationPath $tarFile
    Show-Success "Download concluido."
}
catch {
    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue
    Invoke-Die "Falha no download: $($_.Exception.Message)"
}

# ========================================================
# 4. VALIDAR HASH SHA-256
# ========================================================

Show-Step "Validando hash SHA-256..."

try {
    $actualHash = (Get-FileHash -LiteralPath $tarFile -Algorithm SHA256).Hash
}
catch {
    Invoke-Die "Nao foi possivel calcular o hash: $($_.Exception.Message)"
}

if ($actualHash -ine $expectedHash) {
    Write-Host "     Esperado: $expectedHash" -ForegroundColor Red
    Write-Host "     Recebido: $actualHash" -ForegroundColor Red
    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue
    Invoke-Die "O hash do arquivo nao confere!"
}

Show-Success "Hash SHA-256 validado com sucesso."

# ========================================================
# 5. EXTRAIR ARQUIVO TAR
# ========================================================

Show-Step "Extraindo dependencias em '$SharedDir'..."

if (-not (Test-CommandExists "tar")) {
    Invoke-Die "O comando tar nao foi encontrado no PATH."
}

try {
    & tar -xf $tarFile -C $SharedDir

    if ($LASTEXITCODE -ne 0) {
        throw "O comando tar terminou com codigo $LASTEXITCODE."
    }

    Remove-Item -LiteralPath $tarFile -Force
    Show-Success "Dependencias extraidas e arquivo temporario removido."
}
catch {
    Invoke-Die "Falha na extracao: $($_.Exception.Message)"
}

# ========================================================
# 6. CRIAR ESTRUTURA DE DIRETORIOS E ARQUIVOS
# ========================================================

Show-Step "Criando estrutura de diretorios e arquivos..."

$directories = @(
    "config",
    "config/dbaccess",
    "docker/licenseserver",
    "docker/dbaccess",
    "docker/appserver",
    "docker/appserver/apo",
    "docker/smartview",
    "protheus_data/system",
    "protheus_data/data",
    "db/init",
    "db/backups"
)

foreach ($dir in $directories) {
    $directoryPath = Join-Path $ProjectRoot $dir
    if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
        New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    }
}

$files = @(
    "docker/appserver/appserver.ini",
    "docker/dbaccess/dbaccess.ini",
    "docker/licenseserver/appserver.ini"
)

foreach ($file in $files) {
    $filePath = Join-Path $ProjectRoot $file
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        New-Item -ItemType File -Path $filePath -Force | Out-Null
    }
}

# Criacao do arquivo de servico do License Server
$LicenseServiceFile = Join-Path $ProjectRoot "config/license-server.service"
@"
[Unit]
Description=TOTVS License Server

[Service]
Type=simple
WorkingDirectory=/totvs/licenseserver/bin/appserver
ExecStart=/totvs/licenseserver/bin/appserver/appsrvlinux
Restart=on-failure

[Install]
WantedBy=multi-user.target
"@ | Set-Content -LiteralPath $LicenseServiceFile -Encoding UTF8 -Force

# Criacao do arquivo de servico do DBAccess
$DbAccessServiceFile = Join-Path $ProjectRoot "config/dbaccess.service"
@"
[Unit]
Description=TOTVS DBAccess

[Service]
Type=simple
WorkingDirectory=/totvs/protheus/bin/dbaccess
ExecStart=/totvs/protheus/bin/dbaccess/multi/dbaccess64
Restart=on-failure

[Install]
WantedBy=multi-user.target
"@ | Set-Content -LiteralPath $DbAccessServiceFile -Encoding UTF8 -Force

# Criacao dos arquivos de configuracao ODBC do DBAccess localmente
$OdbcInstFile = Join-Path $ProjectRoot "config/dbaccess/odbcinst.ini"
@"
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
"@ | Set-Content -LiteralPath $OdbcInstFile -Encoding UTF8 -Force

$OdbcIniFile = Join-Path $ProjectRoot "config/dbaccess/odbc.ini"
@"
[{POSTGRES_DB}]
Description=PostgreSQL
Driver=PostgreSQL ANSI
Trace=Yes
TraceFile=/tmp/psqlodbc_{POSTGRES_DB}.log
Servername=tp-db
Database={POSTGRES_DB}
UserName=protheus
Password={POSTGRES_PASSWORD}
Port=5432
ReadOnly=No
RowVersioning=No
ShowSystemTables=No
ShowOidColumn=No
FakeOidIndex=No
ConnSettings=
"@ | Set-Content -LiteralPath $OdbcIniFile -Encoding UTF8 -Force

# Criacao do arquivo de servico do Smart View
$SmartViewServiceFile = Join-Path $ProjectRoot "config/smart-view-agent.service"
@"
[Unit]
Description=smart-view-agent

[Service]
Type=simple
WorkingDirectory=/usr/sbin/smart-view
ExecStart=/usr/sbin/smart-view/TReports.Agent --urls http://*:7019

[Install]
WantedBy=multi-user.target
"@ | Set-Content -LiteralPath $SmartViewServiceFile -Encoding UTF8 -Force

# Criacao do .dockerignore
$dockerIgnoreFile = Join-Path $ProjectRoot ".dockerignore"
if (-not (Test-Path -LiteralPath $dockerIgnoreFile -PathType Leaf)) {
    @"
shared/
*.tar
*.zip
.git/
.env
"@ | Set-Content -LiteralPath $dockerIgnoreFile -Encoding UTF8
}

# Criacao do .gitignore
$gitIgnoreFile = Join-Path $ProjectRoot ".gitignore"
if (-not (Test-Path -LiteralPath $gitIgnoreFile -PathType Leaf)) {
    @"
# Ignorar arquivos de ambiente locais
.env

# Ignorar banco de dados local
/db/data/
/db/backups/

# Ignorar os binarios e zips baixados
/shared/
*.tar
*.zip

# Ignorar binarios extraidos localmente, preservando configuracoes
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
"@ | Set-Content -LiteralPath $gitIgnoreFile -Encoding UTF8
}

Show-Success "Estrutura de diretorios, servicos e gitignore pronta."

# ========================================================
# 7. CRIAR ARQUIVOS DE AMBIENTE
# ========================================================

Show-Step "Verificando arquivos de ambiente..."

function New-EnvFile {
    param([string]$Destination)

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        @"
POSTGRES_DB=protheus
POSTGRES_USER=postgres
POSTGRES_PASSWORD=protheus_pwd
POSTGRES_PORT=5432
APPSERVER_PORT=1234
DBACCESS_PORT=7890
LICENSESERVER_PORT=5555
SHARED_DIR=./shared
"@ | Set-Content -LiteralPath $Destination -Encoding UTF8
        Show-Success "Arquivo criado: $Destination"
    }
    else {
        Show-Success "Arquivo existente preservado: $Destination"
    }
}

New-EnvFile $EnvExampleFile
New-EnvFile $EnvFile

# Extrai as variaveis do arquivo .env atual para uso dinamico
$EnvVariables = @{}
Get-Content -Path $EnvFile -Encoding UTF8 | Where-Object { $_ -match "^([^#\s][^=]+)=(.*)$" } | ForEach-Object {
    $EnvVariables[$matches[1]] = $matches[2]
}

# Injeta as variaveis no ambiente do Windows para o Docker Compose ler a porta externa corretamente
foreach ($key in $EnvVariables.Keys) {
    [Environment]::SetEnvironmentVariable($key, $EnvVariables[$key], "Process")
}

# ========================================================
# 8. VALIDAR DOCKER E DOCKER COMPOSE
# ========================================================

Show-Step "Verificando Docker..."

if (-not (Test-CommandExists "docker")) {
    Invoke-Die "Docker nao esta acessivel. Inicie o Docker Engine ou Docker Desktop."
}

try {
    & docker info | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha" }
}
catch {
    Invoke-Die "Docker nao esta acessivel. Inicie o Docker Engine ou Docker Desktop."
}

try {
    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha" }
}
catch {
    Invoke-Die "O plugin Docker Compose nao esta disponivel."
}

Show-Success "Docker e Docker Compose estao disponiveis."

# ========================================================
# 9. LOCALIZAR ARQUIVO DOCKER COMPOSE
# ========================================================

Show-Step "Localizando configuracao Docker Compose..."

$composeCandidates = @(
    "docker-compose.yml",
    "compose.yaml",
    "compose.yml",
    "docker-compose.yaml"
)

$composeFile = $null

foreach ($candidate in $composeCandidates) {
    $candidatePath = Join-Path $ProjectRoot $candidate

    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $composeFile = $candidatePath
        break
    }
}

if ($null -eq $composeFile) {
    Invoke-Die "Nenhum arquivo Docker Compose foi encontrado na raiz do projeto."
}

& docker compose -f $composeFile config --quiet

if ($LASTEXITCODE -ne 0) {
    Invoke-Die "A configuracao Docker Compose possui erros. Verifique o YAML e o .env."
}

Show-Success "Configuracao Docker Compose validada."

# ========================================================
# 10. BAIXAR IMAGENS DOCKER
# ========================================================

Show-Step "Atualizando imagens Docker..."

& docker pull postgres:16
if ($LASTEXITCODE -ne 0) {
    Invoke-Die "Falha ao baixar a imagem postgres:16."
}

& docker pull oraclelinux:10
if ($LASTEXITCODE -ne 0) {
    Invoke-Die "Falha ao baixar a imagem oraclelinux:10."
}

Show-Success "Imagens atualizadas."

# ========================================================
# 11. INICIALIZAR CONTAINERS
# ========================================================

Show-Step "Inicializando containers via Docker Compose..."

& docker compose -f $composeFile up -d

if ($LASTEXITCODE -ne 0) {
    & docker compose -f $composeFile logs --tail=100
    Invoke-Die "Falha ao inicializar os containers."
}

Show-Success "Ambiente inicializado."

# ========================================================
# 12. CONFIGURAR BANCO DE DADOS (POSTGRESQL)
# ========================================================

Show-Step "Configurando Banco de Dados (PostgreSQL)..."

Write-Host "     Aguardando o banco de dados ficar online..." -ForegroundColor Cyan
$dbReady = $false
for ($i = 1; $i -le 30; $i++) {
    & docker exec -u postgres $DbContainer pg_isready -t 1 > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dbReady = $true
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $dbReady) { Invoke-Die "O PostgreSQL nao respondeu a tempo." }

# Instalacao de pacotes
& docker exec $DbContainer bash -c "apt-get update >/dev/null 2>&1 && apt-get install -y postgresql postgresql-contrib >/dev/null 2>&1"

# Diretorios e Permissoes
$DbName = $EnvVariables['POSTGRES_DB']
$DbUser = $EnvVariables['POSTGRES_USER']
$DbPwd = $EnvVariables['POSTGRES_PASSWORD']

& docker exec $DbContainer bash -c "mkdir -p /postgres/pg_data/$DbName/data /postgres/pg_data/$DbName/index /postgres/pg_data/$DbName/backup"
& docker exec $DbContainer bash -c 'chown -R postgres:postgres /postgres'

# Construcao do script bash a ser executado internamente
$DbScriptPath = Join-Path $SharedDir "setup_db.sh"
$DbScriptContent = @"
#!/bin/bash
psql -d template1 -c "ALTER USER $DbUser WITH PASSWORD '$DbPwd';" > /dev/null 2>&1
# Tenta criar o usuario, se falhar, apenas atualiza a senha (garante compatibilidade com volumes pre-existentes)
psql -d template1 -tc "SELECT 1 FROM pg_roles WHERE rolname='protheus'" | grep -q 1 || psql -d template1 -c "CREATE USER protheus WITH LOGIN NOSUPERUSER INHERIT CREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT -1 PASSWORD '$DbPwd';"
psql -d template1 -c "ALTER ROLE protheus WITH PASSWORD '$DbPwd';" > /dev/null 2>&1
psql -d template1 -tc "SELECT 1 FROM pg_tablespace WHERE spcname='${DbName}_data'" | grep -q 1 || psql -d template1 -c "CREATE TABLESPACE ${DbName}_data OWNER protheus LOCATION '/postgres/pg_data/${DbName}/data';"
psql -d template1 -tc "SELECT 1 FROM pg_tablespace WHERE spcname='${DbName}_index'" | grep -q 1 || psql -d template1 -c "CREATE TABLESPACE ${DbName}_index OWNER protheus LOCATION '/postgres/pg_data/${DbName}/index';"
DB_READY=`$(psql -d template1 -tc "SELECT 1 FROM pg_database WHERE datname='${DbName}' AND dattablespace = (SELECT oid FROM pg_tablespace WHERE spcname='${DbName}_data')")
if echo "`$DB_READY" | grep -q 1; then
    echo "Banco de dados ja configurado."
else
    psql -d template1 -c "DROP DATABASE IF EXISTS ${DbName};"
    psql -d template1 -c "CREATE DATABASE ${DbName} WITH OWNER protheus TEMPLATE template0 ENCODING 'WIN1252' LC_COLLATE 'C' LC_CTYPE 'C' TABLESPACE ${DbName}_data CONNECTION LIMIT -1;"
fi
"@

$DbScriptContent = $DbScriptContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($DbScriptPath, $DbScriptContent, [System.Text.Encoding]::ASCII)

& docker exec -u postgres $DbContainer bash /shared/setup_db.sh > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n [LOG DE ERRO DO POSTGRESQL]:" -ForegroundColor Red
    & docker exec -u postgres $DbContainer bash /shared/setup_db.sh
    Invoke-Die "O script de banco de dados falhou. Verifique as chaves e syntax." 
}

Remove-Item -LiteralPath $DbScriptPath -Force

Show-Success "Banco de dados provisionado nativamente via script interno."

# ========================================================
# 13. VALIDAR ARQUIVOS DE BINARIOS
# ========================================================

Show-Step "Validando integridade dos arquivos extraídos..."

$RequiredArchives = @(
    (Join-Path $SharedDir $LicenseArchive),
    (Join-Path $SharedDir $DbAccessArchive),
    (Join-Path $SharedDir $AppServerArchive),
    (Join-Path $SharedDir $RpoArchive),
    (Join-Path $SharedDir $SmartViewArchive)
)

foreach ($archive in $RequiredArchives) {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        Invoke-Die "Arquivo necessario nao encontrado: $archive"
    }
}

Show-Success "Arquivos de binarios encontrados."

# ========================================================
# 14. CONFIGURAR E INICIAR O LICENSE SERVER (MODO RAIZ)
# ========================================================

Show-Step "Configurando binarios e servico do License Server nativamente..."

& docker exec $LicenseServerContainer mkdir -p $LicenseServerTarget
& docker exec $LicenseServerContainer tar -xf "/shared/$LicenseArchive" -C $LicenseServerTarget
& docker exec $LicenseServerContainer chmod -R +x $LicenseServerTarget

& docker exec $LicenseServerContainer mkdir -p /lib/x86_64-linux-gnu
& docker exec $LicenseServerContainer cp /totvs/licenseserver/bin/appserver/libbtmonitor.so /lib/x86_64-linux-gnu/

& docker exec $LicenseServerContainer systemctl daemon-reload
& docker exec $LicenseServerContainer systemctl enable license-server
& docker exec $LicenseServerContainer systemctl start license-server

# Tempo estendido para garantir que a TOTVS ative a engine de licencas na porta 5555 antes do DBaccess chamar
Write-Host "     Aguardando o motor de licencas estabilizar (10s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

Show-Success "License Server configurado e inicializado."

# ========================================================
# 15. CONFIGURAR BINARIOS E ODBC DO DBACCESS
# ========================================================

Show-Step "Configurando ODBC, ini, binarios e servico do DBAccess nativamente..."

# 15.1. Extracao dos Binarios e Permissoes
& docker exec $DbAccessContainer mkdir -p $DbAccessTarget
& docker exec $DbAccessContainer tar -xf "/shared/$DbAccessArchive" -C $DbAccessTarget
& docker exec $DbAccessContainer chmod -R +x $DbAccessTarget

# 15.2. Instalação dos Pacotes ODBC
Write-Host "     Baixando e instalando pacotes ODBC..." -ForegroundColor Cyan
$InstallLogs = docker exec $DbAccessContainer bash -c "command -v dnf >/dev/null 2>&1 && dnf install -y unixODBC postgresql-odbc postgresql 2>&1 || microdnf install -y unixODBC postgresql-odbc postgresql 2>&1"

if ($LASTEXITCODE -ne 0) { 
    Write-Host "`n [LOG DE ERRO DO INSTALADOR (DNF/MICRODNF)]:" -ForegroundColor Red
    Write-Host ($InstallLogs | Out-String)
    Invoke-Die "Falha ao instalar pacotes ODBC no tp-dbaccess. Verifique o log acima." 
}

# 15.3. Preenchimento dinamico do odbc.ini, odbcinst.ini e dbaccess.ini baseados no .env
$DbName = $EnvVariables['POSTGRES_DB']
$DbPwd = $EnvVariables['POSTGRES_PASSWORD']
$DbAccessPort = $EnvVariables['DBACCESS_PORT']
$LicensePort = $EnvVariables['LICENSESERVER_PORT']

# Configurando odbc.ini
$OdbcContent = Get-Content -Path $OdbcIniFile -Raw
$OdbcContent = $OdbcContent -replace "{POSTGRES_DB}", $DbName -replace "{POSTGRES_PASSWORD}", $DbPwd
$OdbcContent = $OdbcContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($OdbcIniFile, $OdbcContent, [System.Text.Encoding]::ASCII)

# Configurando odbcinst.ini
$OdbcInstContent = Get-Content -Path $OdbcInstFile -Raw
$OdbcInstContent = $OdbcInstContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($OdbcInstFile, $OdbcInstContent, [System.Text.Encoding]::ASCII)

# Configurando dbaccess.ini 
$DbAccessIniFile = Join-Path $ProjectRoot "docker/dbaccess/dbaccess.ini"
$DbAccessIniContent = @"
[General]
InstallPath=/totvs/protheus/bin/dbaccess
ODBC30=1
Port=$DbAccessPort
ThreadInfo=0
LogFull=0
GlbPRofiler=0
ThreadMin=200
ThreadMax=10000
ThreadInc=100
ConsoleMaxSize=100000000
;LicenseServer=$LicenseServerContainer
;LicensePort=$LicensePort
maxStringSize=100

[POSTGRES]
environments=$DbName
clientlibrary=TO_BE_REPLACED_BY_BASH
CodePage=WIN1252

[POSTGRES/$DbName]
user=protheus
password=$DbPwd
TableSpace=$DbName`_data
IndexSpace=$DbName`_index
"@

$DbAccessIniContent = $DbAccessIniContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($DbAccessIniFile, $DbAccessIniContent, [System.Text.Encoding]::ASCII)

# 15.4. Copiar arquivos de configuracao para os diretorios nativos e aplicar no ODBC do Linux
& docker exec $DbAccessContainer cp /totvs/config/odbcinst.ini /etc/odbcinst.ini
& docker exec $DbAccessContainer cp /totvs/config/odbc.ini /etc/odbc.ini
& docker exec $DbAccessContainer odbcinst -i -d -f /etc/odbcinst.ini > $null
& docker exec $DbAccessContainer odbcinst -i -s -l -f /etc/odbc.ini > $null

# 15.5. Autocorrecao dinamica do caminho da ClientLibrary no dbaccess.ini
Write-Host "     Mapeando biblioteca ODBC no dbaccess.ini..." -ForegroundColor Cyan
$OdbcFixScriptPath = Join-Path $SharedDir "fix_odbc.sh"
$OdbcFixScriptContent = @"
#!/bin/bash
INI_FILE="/totvs/protheus/bin/dbaccess/multi/dbaccess.ini"
ODBC_PATH=`$(find /usr -name "psqlodbc.so" | head -n 1)
if [ -z "`$ODBC_PATH" ]; then
    ODBC_PATH=`$(find /usr -name "psqlodbcw.so" | head -n 1)
fi
if [ -n "`$ODBC_PATH" ]; then
    # Usando redirecionamento para evitar erro de 'Device or resource busy' no sed com bind mounts do Docker
    sed "s|^clientlibrary=.*|clientlibrary=`$ODBC_PATH|g" "`$INI_FILE" > /tmp/dbaccess.ini.tmp
    cat /tmp/dbaccess.ini.tmp > "`$INI_FILE"
    rm -f /tmp/dbaccess.ini.tmp
fi
"@
$OdbcFixScriptContent = $OdbcFixScriptContent.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($OdbcFixScriptPath, $OdbcFixScriptContent, [System.Text.Encoding]::ASCII)

& docker exec $DbAccessContainer bash /shared/fix_odbc.sh > $null 2>&1
Remove-Item -LiteralPath $OdbcFixScriptPath -Force

# 15.6. Validar conexao nativamente via isql
Write-Host "     Testando conexao ODBC com o banco $DbName..." -ForegroundColor Cyan
$IsqlLog = docker exec $DbAccessContainer isql -v $DbName 2>&1

if ($LASTEXITCODE -ne 0) { 
    Write-Host "`n [LOG DE ERRO DA CONEXAO ISQL]:" -ForegroundColor Red
    Write-Host ($IsqlLog | Out-String)
    Invoke-Die "O teste do ODBC falhou (isql). Verifique as credenciais no .env ou o log acima." 
}

# 15.7. Ativar e Iniciar o Servico do DBAccess
& docker exec $DbAccessContainer systemctl daemon-reload
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar systemctl daemon-reload." }

& docker exec $DbAccessContainer systemctl enable dbaccess
& docker exec $DbAccessContainer systemctl start dbaccess

Start-Sleep -Seconds 3

Write-Host "`n Status do Servico (DBAccess):" -ForegroundColor Cyan
& docker exec $DbAccessContainer systemctl --no-pager status dbaccess

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n Logs de erro do Journalctl (DBAccess):" -ForegroundColor Red
    & docker exec $DbAccessContainer journalctl -xeu dbaccess --no-pager | Select-Object -Last 15
    Invoke-Die "Falha ao inicializar o servico do DBAccess nativamente." 
}

Show-Success "DBAccess configurado e inicializado com padrao TOTVS."

# ========================================================
# 16. CONFIGURAR BINARIOS E RPO DO APPSERVER
# ========================================================

Show-Step "Configurando binarios e RPO do AppServer..."

& docker exec $AppServerContainer mkdir -p $AppServerTarget $ApoTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$AppServerContainer'." }

& docker exec $AppServerContainer tar -xf "/shared/$AppServerArchive" -C $AppServerTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$AppServerContainer'." }

& docker exec $AppServerContainer cp "/shared/$RpoArchive" "$ApoTarget/tttm120.rpo"
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$AppServerContainer'." }

& docker exec $AppServerContainer touch "$ApoTarget/custom.rpo"
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$AppServerContainer'." }

& docker exec $AppServerContainer chmod -R +x $AppServerTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$AppServerContainer'." }

Show-Success "Binarios e RPOs do AppServer configurados."

# ========================================================
# 17. CONFIGURAR E INICIAR BINARIOS DO SMART VIEW (MODO RAIZ)
# ========================================================

Show-Step "Configurando binarios e servico do Smart View nativamente..."

& docker exec $SmartViewContainer bash -c "dnf install -y unzip libicu krb5-libs zlib openssl-libs >/dev/null 2>&1"

& docker exec $SmartViewContainer mkdir -p $SmartViewTarget
& docker exec $SmartViewContainer bash -c "unzip -qo /shared/$SmartViewArchive -d $SmartViewTarget"
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao extrair os binarios do Smart View no container." }

& docker exec $SmartViewContainer bash -c "chmod +x $SmartViewTarget/TReports.Agent"

& docker exec $SmartViewContainer systemctl daemon-reload
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar systemctl daemon-reload." }

& docker exec $SmartViewContainer systemctl enable smart-view-agent
& docker exec $SmartViewContainer systemctl start smart-view-agent

Show-Success "Binarios do Smart View configurados e inicializados nativamente via systemd."

# ========================================================
# 18. STATUS DOS CONTAINERS
# ========================================================

Show-Header "STATUS DOS CONTAINERS"

& docker compose -f $composeFile ps

if ($LASTEXITCODE -ne 0) {
    Invoke-Die "Nao foi possivel consultar o status dos containers."
}

# ========================================================
# 19. INICIALIZAR DASHBOARD WEB
# ========================================================

Show-Header "INICIALIZANDO DASHBOARD DE GERENCIAMENTO"

$DashboardUrl = "http://localhost:3000"
Show-Step "Aguardando resposta do Dashboard Web..."

$Ready = $false

for ($i = 1; $i -le 15; $i++) {
    try {
        $null = Invoke-WebRequest -Uri $DashboardUrl -UseBasicParsing -ErrorAction Stop
        $Ready = $true
        break
    }
    catch {
        Start-Sleep -Seconds 1
    }
}

if ($Ready) {
    Show-Success "Dashboard disponível em $DashboardUrl"
    Start-Process $DashboardUrl
}
else {
    Show-Warning "O dashboard nao respondeu a tempo em $DashboardUrl."
    Show-Warning "Verifique os logs do container com: docker compose logs tp-dashboard"
}

# ========================================================
# CONCLUSAO
# ========================================================

Show-Header "PROCESSO CONCLUIDO"
Show-Success "Script finalizado."