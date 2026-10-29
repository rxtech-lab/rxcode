// Synthetic responses based on the public Vercel FOCUS and Gateway contracts.
const http = require('node:http');
http.createServer((req, res) => {
  const reply = (status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  const url = new URL(req.url, 'http://localhost');
  if (req.method !== 'GET') return reply(501, { error: 'Not modeled' });
  if (url.pathname === '/v1/billing/charges') {
    if (req.headers.authorization !== 'Bearer billing-only') return reply(401, {});
    if (url.searchParams.get('teamId') !== 'team_test' || !url.searchParams.has('from') || !url.searchParams.has('to')) return reply(400, {});
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
    return res.end([
      { BilledCost: '42.64', BillingCurrency: 'USD', ServiceName: 'Compute', Tags: { ProjectId: 'project_a' } },
      { BilledCost: '99', BillingCurrency: 'USD', ServiceName: 'Compute', Tags: { ProjectId: 'project_b' } }
    ].map(JSON.stringify).join('\n'));
  }
  if (url.pathname === '/v1/credits') {
    if (url.search) return reply(400, {});
    if (req.headers.authorization === 'Bearer denied') return reply(403, {});
    if (req.headers.authorization === 'Bearer malformed') return reply(200, { balance: true });
    if (req.headers.authorization !== 'Bearer gateway-only') return reply(401, {});
    return reply(200, { balance: '95.50', total_used: '4.50' });
  }
  reply(501, { error: 'Not modeled' });
}).listen(process.env.PORT);
