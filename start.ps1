
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

# 1. VALIDAR CONFIGURACAO DE DOWNLOAD

Show-Step "Validando arquivo de configuracao..."

$configFile = Join-Path $ProjectRoot "config/download.json"

if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    Show-Fail "Arquivo de configuracao '$configFile' nao encontrado."
    exit 1
}

try {
    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Show-Fail "Nao foi possivel ler o JSON: $($_.Exception.Message)"
    exit 1
}

$downloadUrl = [string]$config.url
$expectedHash = ([string]$config.sha256).Trim()

if ([string]::IsNullOrWhiteSpace($downloadUrl) -or [string]::IsNullOrWhiteSpace($expectedHash)) {
    Show-Fail "O arquivo config/download.json deve conter os campos 'url' e 'sha256'."
    exit 1
}

if ($downloadUrl -notmatch '^https?://') {
    Show-Fail "A URL de download deve comecar com http:// ou https://."
    exit 1
}

if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') {
    Show-Fail "O campo sha256 deve conter exatamente 64 caracteres hexadecimais."
    exit 1
}

Show-Success "Arquivo de configuracao validado."

# 2. CRIAR DIRETORIO COMPARTILHADO

$sharedDir = Join-Path $ProjectRoot "shared"

if (-not (Test-Path -LiteralPath $sharedDir -PathType Container)) {
    New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null
}

$tarFile = Join-Path $sharedDir "full.tar"

# 3. BAIXAR DEPENDENCIAS

Show-Step "Baixando dependencias..."

try {
    Download-FileWithBar -Url $downloadUrl -DestinationPath $tarFile
    Show-Success "Download concluido."
}
catch {
    Show-Fail "Falha no download: $($_.Exception.Message)"
    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# 4. VALIDAR HASH SHA-256

Show-Step "Validando hash SHA-256..."

try {
    $actualHash = (Get-FileHash -LiteralPath $tarFile -Algorithm SHA256).Hash
}
catch {
    Show-Fail "Nao foi possivel calcular o hash: $($_.Exception.Message)"
    exit 1
}

if ($actualHash -ine $expectedHash) {
    Show-Fail "O hash do arquivo nao confere!"
    Write-Host "     Esperado: $expectedHash" -ForegroundColor Red
    Write-Host "     Recebido: $actualHash" -ForegroundColor Red
    Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue
    exit 1
}

Show-Success "Hash SHA-256 validado com sucesso."

# 5. EXTRAIR ARQUIVO TAR

Show-Step "Extraindo dependencias em '$sharedDir'..."

if (-not (Test-CommandExists "tar")) {
    Show-Fail "O comando tar nao foi encontrado no PATH."
    exit 1
}

try {
    & tar -xf $tarFile -C $sharedDir

    if ($LASTEXITCODE -ne 0) {
        throw "O comando tar terminou com codigo $LASTEXITCODE."
    }

    Remove-Item -LiteralPath $tarFile -Force
    Show-Success "Dependencias extraidas e arquivo temporario removido."
}
catch {
    Show-Fail "Falha na extracao: $($_.Exception.Message)"
    exit 1
}

# 6. CRIAR ESTRUTURA DE DIRETORIOS E ARQUIVOS

Show-Step "Criando estrutura de diretorios e arquivos..."

$directories = @(
    "docker/appserver",
    "docker/appserver/apo",
    "docker/dbaccess",
    "docker/licenseserver",
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

$dockerIgnoreFile = Join-Path $ProjectRoot ".dockerignore"

if (-not (Test-Path -LiteralPath $dockerIgnoreFile -PathType Leaf)) {
    @("shared/", "*.tar", ".git/", ".env") |
    Set-Content -LiteralPath $dockerIgnoreFile -Encoding UTF8
}

Show-Success "Estrutura de pastas e arquivos pronta."

# 7. CRIAR ARQUIVOS DE AMBIENTE

$envDefault = @(
    "POSTGRES_DB=protheus",
    "POSTGRES_USER=postgres",
    "POSTGRES_PASSWORD=protheus_pwd",
    "POSTGRES_PORT=5432",
    "APPSERVER_PORT=1234",
    "DBACCESS_PORT=7890",
    "LICENSESERVER_PORT=5555",
    "SHARED_DIR=./shared"
)

$envExampleFile = Join-Path $ProjectRoot ".env.example"

if (-not (Test-Path -LiteralPath $envExampleFile -PathType Leaf)) {
    $envDefault | Set-Content -LiteralPath $envExampleFile -Encoding UTF8
    Show-Success "Arquivo .env.example criado."
}

$envFile = Join-Path $ProjectRoot ".env"

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    Show-Step "Criando arquivo .env padrao..."
    $envDefault | Set-Content -LiteralPath $envFile -Encoding UTF8
    Show-Success "Arquivo .env criado."
}
else {
    Show-Success "Arquivo .env existente preservado."
}

# 8. VALIDAR DOCKER E DOCKER COMPOSE

Show-Step "Verificando Docker..."

if (-not (Test-CommandExists "docker")) {
    Show-Fail "Docker nao foi encontrado no PATH. Instale ou inicie o Docker Desktop."
    exit 1
}

try {
    & docker info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker nao esta acessivel. Verifique se o Docker Desktop esta iniciado."
    }

    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "O plugin Docker Compose nao esta disponivel."
    }
}
catch {
    Show-Fail $_.Exception.Message
    exit 1
}

Show-Success "Docker e Docker Compose estao disponiveis."

# 9. BAIXAR IMAGENS DOCKER

Show-Step "Atualizando imagens Docker (PostgreSQL e Oracle Linux)..."

& docker pull postgres:16
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao baixar a imagem postgres:16."
    exit 1
}

& docker pull oraclelinux:10
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao baixar a imagem oraclelinux:10."
    exit 1
}

Show-Success "Imagens atualizadas."

# 10. VALIDAR CONFIGURACAO DO COMPOSE

Show-Step "Validando configuracao Docker Compose..."

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
    Show-Fail "Arquivo Docker Compose nao encontrado na raiz do projeto."
    exit 1
}

& docker compose -f $composeFile config --quiet

if ($LASTEXITCODE -ne 0) {
    Show-Fail "A configuracao Docker Compose possui erros. Verifique os arquivos YAML e o .env."
    exit 1
}

Show-Success "Configuracao Docker Compose validada."

# 11. INICIALIZAR CONTAINERS

Show-Step "Inicializando containers via Docker Compose..."

& docker compose -f $composeFile up -d

if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao inicializar os containers."
    Write-Host "Execute 'docker compose logs' para consultar os erros." -ForegroundColor Yellow
    exit 1
}

Show-Success "Ambiente inicializado."

# 12. CONFIGURAR BINARIOS NO TP-DBACCESS

Show-Step "Configurando binarios do DBAccess..."

$dbaccessContainer = "tp-dbaccess"
$dbaccessArchive = "DBACCESS.TAR"
$dbaccessArchivePath = Join-Path $sharedDir $dbaccessArchive

if (-not (Test-Path -LiteralPath $dbaccessArchivePath -PathType Leaf)) {
    Show-Fail "Arquivo DBAccess nao encontrado em '$dbaccessArchivePath'."
    exit 1
}

& docker exec $dbaccessContainer mkdir -p /totvs/protheus/bin/dbaccess
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao criar o diretorio de binarios no container tp-dbaccess."
    exit 1
}

& docker exec $dbaccessContainer tar -xf "/shared/$dbaccessArchive" -C /totvs/protheus/bin/dbaccess
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao extrair os binarios do DBAccess no container."
    exit 1
}

& docker exec $dbaccessContainer chmod -R +x /totvs/protheus/bin/dbaccess
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao ajustar as permissoes dos binarios do DBAccess."
    exit 1
}

Show-Success "Binarios do DBAccess configurados."

# 13. CONFIGURAR BINARIOS E RPO NO TP-APPSERVER

Show-Step "Configurando binarios e RPO do AppServer..."

$appserverContainer = "tp-appserver"
$appserverArchive = "APPSERVER.TAR"
$rpoArchive = "REPOSITORIO.RPO"

$appserverArchivePath = Join-Path $sharedDir $appserverArchive
$rpoArchivePath = Join-Path $sharedDir $rpoArchive

if (-not (Test-Path -LiteralPath $appserverArchivePath -PathType Leaf)) {
    Show-Fail "Arquivo AppServer nao encontrado em '$appserverArchivePath'."
    exit 1
}

if (-not (Test-Path -LiteralPath $rpoArchivePath -PathType Leaf)) {
    Show-Fail "Arquivo RPO nao encontrado em '$rpoArchivePath'."
    exit 1
}

& docker exec $appserverContainer mkdir -p /totvs/protheus/bin/appserver /totvs/protheus/bin/apo
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao criar os diretorios no container tp-appserver."
    exit 1
}

& docker exec $appserverContainer tar -xf "/shared/$appserverArchive" -C /totvs/protheus/bin/appserver
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao extrair os binarios do AppServer no container."
    exit 1
}

& docker exec $appserverContainer cp "/shared/$rpoArchive" /totvs/protheus/bin/apo/tttm120.rpo
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao disponibilizar o arquivo RPO padrao."
    exit 1
}

& docker exec $appserverContainer touch /totvs/protheus/bin/apo/custom.rpo
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao criar o arquivo custom.rpo."
    exit 1
}

& docker exec $appserverContainer chmod -R +x /totvs/protheus/bin/appserver
if ($LASTEXITCODE -ne 0) {
    Show-Fail "Falha ao ajustar as permissoes dos binarios do AppServer."
    exit 1
}

Show-Success "Binarios e RPOs do AppServer configurados."

# 14. STATUS DOS CONTAINERS

Show-Header "STATUS DOS CONTAINERS"

& docker compose -f $composeFile ps

if ($LASTEXITCODE -ne 0) {
    Show-Fail "Nao foi possivel consultar o status dos containers."
    exit 1
}

Show-Header "PROCESSO CONCLUIDO"
Show-Success "Script executado sem erros."

# ========================================================
# 15. INICIALIZAR DASHBOARD WEB
# ========================================================

Show-Header "INICIALIZANDO DASHBOARD DE GERENCIAMENTO"

if (Test-CommandExists "node") {
    $dashboardScript = Join-Path $ProjectRoot "dashboard/server.js"

    if (Test-Path -LiteralPath $dashboardScript -PathType Leaf) {
        Show-Step "Iniciando servidor do painel Web..."

        # Encerra qualquer instância anterior rodando o server.js para evitar conflito na porta 3000
        Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | 
        Where-Object { $_.CommandLine -like "*dashboard/server.js*" } | 
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

        # Inicia o Node.js em segundo plano
        Start-Process -FilePath "node" `
            -ArgumentList "`"$dashboardScript`"" `
            -WorkingDirectory (Join-Path $ProjectRoot "dashboard") `
            -WindowStyle Hidden

        Start-Sleep -Seconds 1

        Show-Success "Dashboard iniciado em http://localhost:3000"

        # Abre o navegador automaticamente
        Start-Process "http://localhost:3000"
    }
    else {
        Show-Fail "Arquivo '$dashboardScript' nao encontrado."
    }
}
else {
    Write-Host " [!] Node.js nao encontrado no PATH. O dashboard nao foi iniciado automaticamente." -ForegroundColor DarkYellow
}