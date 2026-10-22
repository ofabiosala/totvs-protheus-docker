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

# Criacao do arquivo de servico do Smart View localmente (SOBRESCREVE O ANTIGO COM -Force)
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
# 12. VALIDAR ARQUIVOS DE BINARIOS
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
# 13. CONFIGURAR BINARIOS DO LICENSE SERVER
# ========================================================

Show-Step "Configurando binarios do License Server..."

& docker exec $LicenseServerContainer mkdir -p $LicenseServerTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao criar o diretorio no container '$LicenseServerContainer'." }

& docker exec $LicenseServerContainer tar -xf "/shared/$LicenseArchive" -C $LicenseServerTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao extrair os binarios do License Server no container." }

& docker exec $LicenseServerContainer chmod -R +x $LicenseServerTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao ajustar as permissoes dos binarios do License Server." }

Show-Success "Binarios do License Server configurados."

# ========================================================
# 14. CONFIGURAR BINARIOS DO DBACCESS
# ========================================================

Show-Step "Configurando binarios do DBAccess..."

& docker exec $DbAccessContainer mkdir -p $DbAccessTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$DbAccessContainer'." }

& docker exec $DbAccessContainer tar -xf "/shared/$DbAccessArchive" -C $DbAccessTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$DbAccessContainer'." }

& docker exec $DbAccessContainer chmod -R +x $DbAccessTarget
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar comando no container '$DbAccessContainer'." }

Show-Success "Binarios do DBAccess configurados."

# ========================================================
# 15. CONFIGURAR BINARIOS E RPO DO APPSERVER
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
# 16. CONFIGURAR E INICIAR BINARIOS DO SMART VIEW (MODO RAIZ)
# ========================================================

Show-Step "Configurando binarios e servico do Smart View nativamente..."

# 16.1. Garantir que ferramentas e bibliotecas necessarias (.NET/ICU) existam na imagem base
& docker exec $SmartViewContainer bash -c "dnf install -y unzip libicu krb5-libs zlib openssl-libs >/dev/null 2>&1"

# 16.2. Extrair binarios em /usr/sbin/smart-view
& docker exec $SmartViewContainer mkdir -p $SmartViewTarget
& docker exec $SmartViewContainer bash -c "unzip -qo /shared/$SmartViewArchive -d $SmartViewTarget"
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao extrair os binarios do Smart View no container." }

# Garante permissao de execucao no binario real
& docker exec $SmartViewContainer bash -c "chmod +x $SmartViewTarget/TReports.Agent"

# 16.3. Ativar e Iniciar o Servico (O arquivo ja esta mapeado pelo Compose)
& docker exec $SmartViewContainer systemctl daemon-reload
if ($LASTEXITCODE -ne 0) { Invoke-Die "Falha ao executar systemctl daemon-reload." }

& docker exec $SmartViewContainer systemctl enable smart-view-agent
& docker exec $SmartViewContainer systemctl start smart-view-agent

# Aguarda 3 segundos para garantir que o processo nao caiu instantaneamente
Start-Sleep -Seconds 3

Write-Host "`n Status do Servico no SO Interno:" -ForegroundColor Cyan
& docker exec $SmartViewContainer systemctl --no-pager status smart-view-agent

# Se o comando status falhar, exibe o log de erro real
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n Logs de erro do Journalctl:" -ForegroundColor Red
    & docker exec $SmartViewContainer journalctl -xeu smart-view-agent --no-pager | Select-Object -Last 15
    Invoke-Die "Falha ao inicializar o servico do Smart View nativamente." 
}

Show-Success "Binarios do Smart View configurados e inicializados nativamente via systemd."

# ========================================================
# 17. STATUS DOS CONTAINERS
# ========================================================

Show-Header "STATUS DOS CONTAINERS"

& docker compose -f $composeFile ps

if ($LASTEXITCODE -ne 0) {
    Invoke-Die "Nao foi possivel consultar o status dos containers."
}

# ========================================================
# 18. INICIALIZAR DASHBOARD WEB
# ========================================================

Show-Header "INICIALIZANDO DASHBOARD DE GERENCIAMENTO"

$DashboardUrl = "http://localhost:3000"
Show-Step "Aguardando resposta do Dashboard Web..."

$Ready = $false

# Aguarda ate 15 segundos para o container subir e responder
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