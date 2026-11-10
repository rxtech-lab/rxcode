// Stateful ciphertext-only fixture for the Flowcy task activity API.
const http = require('http');
const stored = new Map();
http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const reply = (status, value) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(value));
    };
    if (req.headers.authorization !== 'Bearer simulation-token') return reply(401, { error: 'Unauthorized' });
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname.includes('/repositories/failure/')) return reply(503, { error: 'Storage unavailable' });
    if (req.method === 'PUT' && url.pathname.endsWith('/tasks/task/activity')) {
      const envelope = JSON.parse(body);
      if (envelope.version !== 1 || Object.keys(envelope).some(k => !['version', 'sender', 'recipients'].includes(k))) return reply(400, { error: 'Ciphertext required' });
      for (const box of Object.values(envelope.recipients)) {
        if (Object.keys(box).some(k => !['nonce', 'ciphertext'].includes(k))) return reply(400, { error: 'Ciphertext required' });
      }
      stored.set(envelope.sender, envelope);
      return reply(200, envelope);
    }
    if (req.method === 'GET' && url.pathname.endsWith('/activity')) {
      const recipient = url.searchParams.get('recipient');
      return reply(200, { items: [...stored.values()].filter(e => e.recipients[recipient]).map(envelope => ({ taskId: 'task', envelope })), nextCursor: null });
    }
    reply(404, { error: 'Outside contract' });
  });
}).listen(process.env.PORT || 4592);
