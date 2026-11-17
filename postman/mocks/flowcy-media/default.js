// Native account media contracts from github-pm/app/api/v1/{models,ai/*}.
// Fixtures generate no billed media and do not forward requests to a provider.
const http = require('http');
const requests = new Map();
http.createServer(async (req, res) => {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  const json = (status, body) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
  const path = new URL(req.url, 'http://simulation.local').pathname;
  const key = req.headers['idempotency-key'];
  if (key) requests.set(key, [...(requests.get(key) ?? []), {key, authorization: req.headers.authorization}]);
  if (req.headers.authorization !== 'Bearer fixture-valid') return json(401, {error: 'Unauthorized'});
  if (req.method === 'GET' && path.endsWith('/api/v1/models')) {
    return json(200, {models: [
      {id: 'fixture-image', provider: 'gateway', displayName: 'Fixture Image', capability: 'image', labels: ['chat', 'image']},
      {id: 'fixture-image', provider: 'gateway', displayName: 'Fixture Image', capability: 'chat', labels: ['chat', 'image']},
      {id: 'fixture-video', provider: 'google', displayName: 'Fixture Video', capability: 'video', labels: ['video']},
      {id: 'fixture-audio', provider: 'gateway', displayName: 'Fixture Audio', capability: 'speech', labels: ['audio']}
    ]});
  }
  // Test observation endpoint, deliberately outside the modeled production routes.
  if (req.method === 'GET' && path.includes('/api/v1/simulation/requests/')) return json(200, {requests: requests.get(path.split('/').at(-1)) ?? []});
  if (req.method === 'POST' && path.endsWith('/api/v1/ai/images')) {
    const body = req.body ?? JSON.parse(raw);
    if (!key || !body.prompt || body.model !== 'fixture-image') return json(400, {error: 'Invalid image request'});
    if (body.prompt === 'rate-limit') return json(429, {error: 'Media rate limit reached'});
    if (body.prompt === 'invalid-provider-response') { res.writeHead(502, {'Content-Type':'text/html'}); return res.end('<html>Unavailable</html>'); }
    return json(200, {images:[{b64_json:'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==', mime_type:'image/png'}]});
  }
  if (req.method === 'POST' && path.endsWith('/api/v1/ai/videos')) {
    const body = req.body ?? JSON.parse(raw);
    if (!key || body.model !== 'fixture-video' || !body.prompt || !body.aspect_ratio || !body.duration_seconds || !body.person_generation) return json(400, {error:'Invalid video request'});
    return json(202, {job_id:'flowcy-fixture-video', status:'running', poll_url:'/api/v1/jobs/flowcy-fixture-video'});
  }
  if (req.method === 'GET' && path.endsWith('/api/v1/jobs/flowcy-fixture-video')) return json(200, {job_id:'flowcy-fixture-video', status:'running', progress_percent:5});
  return json(501, {error:'Outside media simulation contract'});
}).listen(process.env.PORT);
