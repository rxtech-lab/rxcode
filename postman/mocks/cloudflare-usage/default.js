// Synthetic examples shaped from Cloudflare's documented Workers/R2 GraphQL queries.
// This checks the HTTP contract; it is not a live billing oracle.
const http = require('node:http');
http.createServer((req, res) => {
  const reply = (status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(value));
  };
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
