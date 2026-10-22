const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = 3000;
const PUBLIC_DIR = path.join(__dirname, 'public');

// Adicionado o 'tp-smartview' na lista de monitoramento
const TARGET_CONTAINERS = [
    'tp-db',
    'tp-licenseserver',
    'tp-dbaccess',
    'tp-appserver',
    'tp-smartview'
];

function executeCommand(command) {
    return new Promise((resolve, reject) => {
        exec(command, { maxBuffer: 1024 * 1024 * 5 }, (error, stdout, stderr) => {
            const output = (stdout || '') + (stderr || '');
            if (error && !output) {
                return reject(error.message);
            }
            resolve(output.trim());
        });
    });
}

const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        return res.end();
    }

    const parsedUrl = url.parse(req.url, true);

    // API: Listar status e metricas dos containers
    if (parsedUrl.pathname === '/api/containers' && req.method === 'GET') {
        try {
            // Executa docker ps e docker stats em paralelo
            const [psOutput, statsOutput] = await Promise.all([
                executeCommand('docker ps -a --format "{{json .}}"'),
                executeCommand('docker stats --no-stream --format "{{json .}}"').catch(() => '')
            ]);

            const psLines = psOutput ? psOutput.split('\n').filter(Boolean) : [];
            const statsLines = statsOutput ? statsOutput.split('\n').filter(Boolean) : [];

            const allContainers = psLines.map(line => {
                try { return JSON.parse(line); } catch (e) { return null; }
            }).filter(Boolean);

            const allStats = statsLines.map(line => {
                try { return JSON.parse(line); } catch (e) { return null; }
            }).filter(Boolean);

            const filtered = TARGET_CONTAINERS.map(name => {
                const found = allContainers.find(c => c.Names === name);
                const stats = allStats.find(s => s.Name === name);

                if (found) {
                    const cpuPercent = stats ? parseFloat(stats.CPUPerc.replace('%', '')) || 0 : 0;
                    const memPercent = stats ? parseFloat(stats.MemPerc.replace('%', '')) || 0 : 0;

                    return {
                        name: found.Names,
                        status: found.Status,
                        state: found.State,
                        image: found.Image,
                        ports: found.Ports || '-',
                        stats: stats ? {
                            cpu: stats.CPUPerc,
                            cpuRaw: cpuPercent,
                            memUsage: stats.MemUsage,
                            memPercent: stats.MemPerc,
                            memRaw: memPercent
                        } : null
                    };
                }
                return {
                    name: name,
                    status: 'Nao criado',
                    state: 'not_found',
                    image: '-',
                    ports: '-',
                    stats: null
                };
            });

            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            return res.end(JSON.stringify(filtered));
        } catch (err) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: String(err) }));
        }
    }

    // API: Buscar logs de um container específico
    if (parsedUrl.pathname === '/api/logs' && req.method === 'GET') {
        const container = parsedUrl.query.container;
        const tail = parsedUrl.query.tail || '150';

        if (!TARGET_CONTAINERS.includes(container)) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: 'Container nao autorizado' }));
        }

        try {
            const logs = await executeCommand(`docker logs --tail ${tail} --timestamps ${container}`);
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            return res.end(JSON.stringify({ container, logs: logs || 'Nenhum log registrado ainda.' }));
        } catch (err) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: String(err) }));
        }
    }

    // API: Executar ação (start, stop, restart)
    if (parsedUrl.pathname === '/api/action' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', async () => {
            try {
                const { action, container } = JSON.parse(body || '{}');

                if (!['start', 'stop', 'restart'].includes(action)) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    return res.end(JSON.stringify({ error: 'Acao invalida' }));
                }

                if (!TARGET_CONTAINERS.includes(container)) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    return res.end(JSON.stringify({ error: 'Container nao autorizado' }));
                }

                await executeCommand(`docker ${action} ${container}`);

                res.writeHead(200, { 'Content-Type': 'application/json' });
                return res.end(JSON.stringify({ success: true, message: `${action} executado em ${container}` }));
            } catch (err) {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                return res.end(JSON.stringify({ error: String(err) }));
            }
        });
        return;
    }

    // Servir arquivos estáticos
    let filePath = path.join(PUBLIC_DIR, req.url === '/' ? 'index.html' : parsedUrl.pathname);
    const ext = path.extname(filePath);

    const mimeTypes = {
        '.html': 'text/html; charset=utf-8',
        '.css': 'text/css; charset=utf-8',
        '.js': 'application/javascript; charset=utf-8'
    };

    fs.readFile(filePath, (err, content) => {
        if (err) {
            res.writeHead(404, { 'Content-Type': 'text/plain' });
            return res.end('404 Not Found');
        }
        res.writeHead(200, { 'Content-Type': mimeTypes[ext] || 'text/plain' });
        res.end(content);
    });
});

server.listen(PORT, () => {
    console.log(`[Dashboard Protheus] Servidor rodando em http://localhost:${PORT}`);
});