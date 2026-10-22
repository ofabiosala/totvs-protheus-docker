Write-Host "Iniciando limpeza extrema do Docker..." -ForegroundColor Cyan

# 1. Para e remove todos os containers

$containers = docker ps -a -q
if ($containers) {
    Write-Host "Limpando containers..." -ForegroundColor Yellow
    docker stop $containers
    docker rm -f $containers
}

# 2. Remove todas as imagens

$images = docker images -a -q
if ($images) {
    Write-Host "Limpando imagens..." -ForegroundColor Yellow
    docker rmi -f $images
}

# 3. Remove todos os volumes

$volumes = docker volume ls -q
if ($volumes) {
    Write-Host "Limpando volumes..." -ForegroundColor Yellow
    docker volume rm $volumes
}

# 4. Remove todas as redes

$networks = docker network ls -q
if ($networks) {
    Write-Host "Limpando redes..." -ForegroundColor Yellow
    # Silenciando erros pois as redes default não podem ser apagadas
    docker network rm $networks 2>$null
}

# 5. Limpa cache de build e resíduos

Write-Host "Executando system prune final..." -ForegroundColor Yellow
docker system prune -a --volumes -f

Write-Host "Limpeza concluida com sucesso." -ForegroundColor Green