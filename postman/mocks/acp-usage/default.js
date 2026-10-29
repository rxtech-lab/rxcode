// Synthetic quota fixtures following the provider endpoint contracts.
const http = require('node:http');
http.createServer((req, res) => {
  const reply = (status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  if (req.headers.authorization === 'Bearer denied') return reply(403, { error: 'Forbidden' });
  if (req.headers.authorization !== 'Bearer simulation-only') return reply(401, { error: 'Unauthorized' });
  if (req.method === 'GET' && req.url === '/inference/go/v1/usage') {
    return reply(200, { usage: { rolling: { percent: 0.5 }, weekly: { percent: 42 } } });
  }
  if (req.method === 'POST' && req.url === '/v1internal:retrieveUserQuotaSummary') {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    if (JSON.stringify(body) !== '{}' || req.headers['user-agent'] !== 'antigravity/acp') return reply(400, { error: 'Invalid request' });
    return reply(200, { groups: [{ displayName: 'Gemini', buckets: [
      { bucketId: 'gemini-5h', remainingFraction: 0.75, resetTime: '2026-10-29T00:00:00Z' },
      { bucketId: 'gemini-weekly', remainingFraction: 0.25 }
    ] }] });
  }
  reply(501, { error: 'Not modeled' });
}).listen(process.env.PORT);
