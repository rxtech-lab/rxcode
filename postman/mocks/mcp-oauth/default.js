// Local OAuth/MCP contract fixture: RFC 6749 refresh grant and MCP HTTP 401.
// All credentials are synthetic. No upstream provider or real account is used.
const http = require('http');
const stateKey = 'mcp-oauth.rotation';
http.createServer(async (req, res) => {
  const send = (status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const path = req.url.split('?')[0];
  if (path === '/reset' && req.method === 'POST') {
    await pm.state.set(stateKey, 0);
    return send(200, { reset: true });
  }
  if (path === '/stats') return send(200, { rotations: (await pm.state.get(stateKey)) || 0 });
  if (path === '/token' && req.method === 'POST') {
    const form = new URLSearchParams(typeof req.body === 'string' ? req.body : '');
    // Some CLI versions parse form bodies into an object before the handler.
    const field = (name) => form.get(name) ?? req.body?.[name];
    const rotation = (await pm.state.get(stateKey)) || 0;
    const expected = rotation ? `fixture-refresh-${rotation}` : 'fixture-refresh';
    if (field('grant_type') !== 'refresh_token' || field('client_id') !== 'rxcode-fixture' ||
        !field('resource')?.endsWith('/oauth/mcp')) return send(400, { error: 'invalid_request' });
    if (field('refresh_token') !== expected) return send(400, { error: 'invalid_grant' });
    const next = rotation + 1;
    await pm.state.set(stateKey, next);
    return send(200, { access_token: `fixture-access-${next}`, refresh_token: `fixture-refresh-${next}`,
      token_type: 'Bearer', expires_in: 3600 });
  }
  if (['/mcp', '/messages'].includes(path)) {
    const rotation = (await pm.state.get(stateKey)) || 0;
    // Reject the first issued token once, simulating early invalidation even
    // though expires_in says the token is still valid for an hour.
    if (rotation < 2 || req.headers.authorization !== `Bearer fixture-access-${rotation}`) {
      res.writeHead(401, { 'WWW-Authenticate': 'Bearer error="invalid_token"' });
      return res.end();
    }
    if (req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Mcp-Session-Id': 'fixture-session' });
      res.write('event: endpoint\ndata: /oauth/messages?session=fixture-session\n\n');
      return setTimeout(() => res.end('event: message\ndata: {"jsonrpc":"2.0","id":7,"result":{}}\n\n'), 25);
    }
    if (req.headers['x-fixture-header'] !== 'preserved') return send(400, { error: 'missing_header' });
    return send(200, { jsonrpc: '2.0', id: req.body?.id ?? 7, result: { accepted: true } });
  }
  return send(501, { error: 'Endpoint not modeled by this fixture' });
}).listen(process.env.PORT || 49491);
