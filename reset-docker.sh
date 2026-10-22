#!/bin/bash

echo "Iniciando limpeza extrema do Docker..."

# 1. Para e remove todos os containers (em execução ou parados)

if [ "$(docker ps -a -q)" ]; then
    echo "Limpando containers..."
    docker stop $(docker ps -a -q)
    docker rm -f $(docker ps -a -q)
fi

# 2. Remove todas as imagens

if [ "$(docker images -a -q)" ]; then
    echo "Limpando imagens..."
    docker rmi -f $(docker images -a -q)
fi

# 3. Remove todos os volumes

if [ "$(docker volume ls -q)" ]; then
    echo "Limpando volumes..."
    docker volume rm $(docker volume ls -q)
fi

# 4. Remove todas as redes customizadas

if [ "$(docker network ls -q)" ]; then
    echo "Limpando redes..."
    # Suprimimos o erro aqui pois o Docker não permite deletar as redes default (bridge, host, none)
    docker network rm $(docker network ls -q) 2>/dev/null
fi

# 5. Limpa cache de build e qualquer resíduo do sistema

echo "Executando system prune final..."
docker system prune -a --volumes -f

echo "Limpeza concluida com sucesso."