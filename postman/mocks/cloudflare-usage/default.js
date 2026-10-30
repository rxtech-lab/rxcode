// Synthetic examples shaped from Cloudflare's documented Workers/R2 GraphQL queries.
// This checks the HTTP contract; it is not a live billing oracle.
const http = require('node:http');
http.createServer(async (req, res) => {
  const reply = (status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  // OAuth fixtures use synthetic credentials; token rotation is single-use.
  if (req.url.startsWith('/oauth-test/')) {
    const url = new URL(req.url, 'http://fixture');
    const scenario = url.pathname.split('/')[2];
    const key = `cloudflare-usage.${scenario}`;
    if (url.pathname.endsWith('/reset')) {
      await pm.state.set(key, { refreshes: 0, reads: 0 });
      return reply(200, {});
    }
    const state = (await pm.state.get(key)) || { refreshes: 0, reads: 0 };
    if (url.pathname.endsWith('/stats')) return reply(200, state);
    if (url.pathname.endsWith('/oauth2/token') && req.method === 'POST') {
      const form = new URLSearchParams(typeof req.body === 'string' ? req.body : '');
      if (form.get('grant_type') !== 'refresh_token' || form.get('client_id') !== 'fixture-client' ||
          !['fixture-refresh', 'fixture-rotated'].includes(form.get('refresh_token'))) return reply(400, { error: 'invalid_request' });
      state.refreshes += 1;
      await pm.state.set(key, state);
      if (scenario === 'refresh-failure') return reply(400, { error: 'invalid_grant' });
      if (state.refreshes > 1 && form.get('refresh_token') === 'fixture-refresh') return reply(400, { error: 'invalid_grant' });
      const token = { access_token: 'fixture-renewed', expires_in: 3600, token_type: 'bearer' };
      if (scenario !== 'keep-refresh') token.refresh_token = 'fixture-rotated';
      return reply(200, token);
    }
    if (url.pathname.endsWith('/memberships')) {
      state.reads += 1;
      await pm.state.set(key, state);
      if (scenario === 'forbidden') return reply(403, { errors: [{ message: 'Forbidden' }] });
      if (scenario === 'always-401' || req.headers.authorization !== 'Bearer fixture-renewed') return reply(401, {});
      return reply(200, { success: true, result: [{ status: 'accepted', account: { id: 'fixture-account', name: 'Fixture' } }] });
    }
    return reply(501, { error: 'Not modeled' });
  }
  if (req.method !== 'POST' || req.url !== '/client/v4/graphql') return reply(501, { error: 'Not modeled' });
  const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  const { query, variables } = body || {};
  if (!query || variables?.account !== 'test-account' ||
      req.headers.authorization !== 'Bearer simulation-only' ||
      Date.parse(variables.end) - Date.parse(variables.start) !== 86400000 ||
      !query.includes('accountTag: $account')) return reply(400, { error: 'Invalid request contract' });
  if (variables.resource === 'denied') return reply(403, { error: 'Forbidden' });
  const account = { activity: [{ sum: { requests: 42, errors: 2 } }] };
  if (variables.resource === 'partial') return reply(200, { data: { viewer: { accounts: [account] } }, errors: [{ message: 'Denied dataset' }] });
  if (variables.resource === 'assets' && query.includes('bucketName: $resource') &&
      query.includes('orderBy: [datetime_DESC]') && query.includes('r2StorageAdaptiveGroups(limit: 1')) {
    account.activity = [{ sum: { requests: 42 } }];
    account.storage = [{ max: { payloadSize: 2048, metadataSize: 128, objectCount: 7 }, dimensions: { datetime: variables.end } }];
  } else if (variables.resource !== 'api' || !query.includes('scriptName: $resource') ||
             !query.includes('workersInvocationsAdaptive')) {
    return reply(400, { error: 'Invalid resource filter' });
  }
  reply(200, { data: { viewer: { accounts: [account] } } });
}).listen(process.env.PORT);
