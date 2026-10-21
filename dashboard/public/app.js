const cardsContainer = document.getElementById('cards-grid');
const btnRefresh = document.getElementById('btn-refresh');

const modalLogs = document.getElementById('modal-logs');
const modalTitle = document.getElementById('modal-title');
const logOutput = document.getElementById('log-output');

let activeLogContainer = null;
let logIntervalId = null;

async function fetchContainers() {
    try {
        const res = await fetch('/api/containers');
        const containers = await res.json();
        renderCards(containers);
    } catch (err) {
        console.error('Erro ao buscar status dos containers:', err);
    }
}

function getBarColor(percentage) {
    if (percentage > 85) return '#ef4444'; // Vermelho (crítico)
    if (percentage > 60) return '#f59e0b'; // Amarelo (alerta)
    return '#38bdf8';                     // Azul claro (normal)
}

function renderCards(containers) {
    cardsContainer.innerHTML = '';

    containers.forEach(item => {
        const card = document.createElement('div');
        card.className = 'card';

        const stateLabel = {
            'running': 'Em Execução',
            'exited': 'Parado',
            'restarting': 'Reiniciando',
            'not_found': 'Não Encontrado'
        }[item.state] || item.state;

        // Seção dinâmica de métricas
        let metricsHtml = '';
        if (item.state === 'running' && item.stats) {
            const cpuColor = getBarColor(item.stats.cpuRaw);
            const memColor = getBarColor(item.stats.memRaw);

            metricsHtml = `
              <div class="metrics-box">
                <div class="metric-item">
                  <div class="metric-header">
                    <span>CPU</span>
                    <span>${item.stats.cpu}</span>
                  </div>
                  <div class="metric-bar-bg">
                    <div class="metric-bar-fill" style="width: ${Math.min(item.stats.cpuRaw, 100)}%; background-color: ${cpuColor};"></div>
                  </div>
                </div>
                <div class="metric-item">
                  <div class="metric-header">
                    <span>Memória</span>
                    <span>${item.stats.memPercent}</span>
                  </div>
                  <div class="metric-bar-bg">
                    <div class="metric-bar-fill" style="width: ${Math.min(item.stats.memRaw, 100)}%; background-color: ${memColor};"></div>
                  </div>
                  <span class="metric-sub">${item.stats.memUsage}</span>
                </div>
              </div>
            `;
        }

        card.innerHTML = `
      <div>
        <div class="card-header">
          <span class="container-name">${item.name}</span>
          <span class="badge badge-${item.state}">
            <span class="status-dot"></span>
            ${stateLabel}
          </span>
        </div>
        <div class="card-body">
          <p><strong>Status:</strong> ${item.status}</p>
          <p><strong>Portas:</strong> ${item.ports}</p>
          ${metricsHtml}
        </div>
      </div>
      <div class="card-actions">
        <button class="btn-start" onclick="sendAction('start', '${item.name}')" ${item.state === 'running' ? 'disabled' : ''}>Iniciar</button>
        <button class="btn-stop" onclick="sendAction('stop', '${item.name}')" ${item.state !== 'running' ? 'disabled' : ''}>Parar</button>
        <button class="btn-restart" onclick="sendAction('restart', '${item.name}')" ${item.state !== 'running' ? 'disabled' : ''}>Reiniciar</button>
        <button class="btn-logs" onclick="openLogs('${item.name}')">Ver Logs</button>
      </div>
    `;
        cardsContainer.appendChild(card);
    });
}

async function sendAction(action, container) {
    const buttons = document.querySelectorAll(`button`);
    buttons.forEach(b => b.disabled = true);

    try {
        const res = await fetch('/api/action', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action, container })
        });
        if (!res.ok) {
            const data = await res.json();
            alert(`Erro: ${data.error || 'Falha na acao'}`);
        }
    } catch (err) {
        alert('Erro de conexao com o servidor');
    } finally {
        await fetchContainers();
    }
}

// Funções do Modal de Logs
async function openLogs(containerName) {
    activeLogContainer = containerName;
    modalTitle.textContent = `Logs: ${containerName}`;
    logOutput.textContent = 'Carregando registros...';
    modalLogs.classList.remove('hidden');

    await fetchLogs();

    if (logIntervalId) clearInterval(logIntervalId);
    logIntervalId = setInterval(fetchLogs, 2000);
}

async function fetchLogs() {
    if (!activeLogContainer) return;

    try {
        const res = await fetch(`/api/logs?container=${activeLogContainer}&tail=150`);
        if (res.ok) {
            const data = await res.json();
            const isAtBottom = (logOutput.parentElement.scrollHeight - logOutput.parentElement.scrollTop) <= (logOutput.parentElement.clientHeight + 50);

            logOutput.textContent = data.logs || 'Sem logs disponíveis.';

            if (isAtBottom) {
                logOutput.parentElement.scrollTop = logOutput.parentElement.scrollHeight;
            }
        }
    } catch (err) {
        console.error('Falha ao obter logs:', err);
    }
}

function closeLogs() {
    modalLogs.classList.add('hidden');
    activeLogContainer = null;
    if (logIntervalId) {
        clearInterval(logIntervalId);
        logIntervalId = null;
    }
}

// Fechar modal ao clicar fora dele
modalLogs.addEventListener('click', (e) => {
    if (e.target === modalLogs) {
        closeLogs();
    }
});

btnRefresh.addEventListener('click', fetchContainers);

// Carregamento inicial do grid de containers
fetchContainers();
setInterval(fetchContainers, 4000);