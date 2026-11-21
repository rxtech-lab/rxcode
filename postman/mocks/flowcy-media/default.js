// Native account media contracts from github-pm/app/api/v1/{models,ai/*}.
// Fixtures generate no billed media and do not forward requests to a provider.
const http = require('http');
const requests = new Map();
http.createServer(async (req, res) => {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  const json = (status, body) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
  const url = new URL(req.url, 'http://simulation.local');
  const path = url.pathname;
  const key = req.headers['idempotency-key'];
  if (key) requests.set(key, [...(requests.get(key) ?? []), {key, authorization: req.headers.authorization}]);
  if (req.headers.authorization !== 'Bearer fixture-valid') return json(401, {error: 'Unauthorized'});
  if (req.method === 'GET' && path.endsWith('/api/v1/models')) {
    return json(200, {models: [
      {id: 'fixture-image', provider: 'gateway', displayName: 'Fixture Image', capability: 'image', labels: ['chat', 'image']},
      {id: 'fixture-image', provider: 'gateway', displayName: 'Fixture Image', capability: 'chat', labels: ['chat', 'image']},
      {id: 'fixture-video', provider: 'google', displayName: 'Fixture Video', capability: 'video', labels: ['video']},
      {id: 'fixture-audio', provider: 'gateway', displayName: 'Fixture Audio', capability: 'speech', labels: ['audio']},
      {id: 'azure-neural-tts', provider: 'azure', displayName: 'Azure Neural', capability: 'speech', labels: ['audio']},
      {id: 'azure-hd-tts', provider: 'azure', displayName: 'Azure HD', capability: 'speech', labels: ['audio']},
      {id: 'gemini-3.8-flash-tts', provider: 'google', displayName: 'Gemini Flash TTS', capability: 'speech', labels: ['audio']}
    ].filter(model => !url.searchParams.has('capability') || url.searchParams.get('capability') === model.capability)});
  }
  if (req.method === 'GET' && path.endsWith('/api/v1/ai/voices')) {
    if (url.searchParams.get('provider') !== 'azure') return json(400, {error: 'Only Azure has a remote voice catalog.'});
    return json(200, [
      {ShortName: 'fr-FR-DeniseNeural', DisplayName: 'Denise', Locale: 'fr-FR'},
      {ShortName: 'en-US-Ava:DragonHDLatestNeural', DisplayName: 'Ava HD', Locale: 'en-US'}
    ]);
  }
  if (req.method === 'POST' && path.endsWith('/api/v1/ai/speech')) {
    const body = req.body ?? JSON.parse(raw);
    if (!key) return json(400, {error: 'Missing idempotency key'});
    if (body.text === 'rate-limit') return json(429, {error: 'Speech allowance reached'});
    if (body.text === 'missing-audio') return json(200, {audio_base64: '', mime_type: 'audio/wav'});
    const azure = body.provider === 'azure' && body.ssml?.includes("xml:lang='fr-FR'")
      && body.ssml?.includes("<voice name='fr-FR-DeniseNeural'>Ready &amp; waiting.</voice>");
    const gemini = body.provider === 'gemini' && body.transcript === 'Ready & waiting.'
      && body.speakers?.length === 1 && body.speakers[0].voice === 'Kore';
    const gateway = body.provider === 'gateway' && body.model === 'fixture-audio'
      && body.voice === 'fixture-speaker' && body.text === 'Ready & waiting.';
    if (!(azure || gemini || gateway)) return json(400, {error: 'Unexpected model, voice or speech text'});
    if (azure || gateway) {
      // 35 ms of a 450 Hz test tone encoded as mono MP3.
      return json(200, {mime_type: 'audio/mpeg', audio_base64: '//M0xAAM6EacX0wYAgblskAAXr152Zr32CQCYEwJgTBuJZ++DgIAgGMTnw/ggCGXB9+CBwuGNQJn8H3dPu6fd0pG4vFuAOU5//M0xAcOkLaEAZtQAI2gHJBpjAWbTbBycIukz8OLZCQRG2F0AEoDICv4rCKEUQ/49Hpw+H3yoKiI99YKiI9/BWrWNy//r0Ma//M0xAcOiQKoAZk4AKxi3+/15crufpXMByC4QpmK554tGw96WyZYalB//fONKIBe7KhkKhj/CpIDCQ7/4qVFDVX8EF23JaAA//M0xAcJwAXNn8AYAOrDUq4s8WDqzsFXCK3Oq+2eiJ4l/+HVnYllv/hqeiKVTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVV'});
    }
    // A short 24 kHz mono PCM waveform, in the same WAV envelope Flowcy uses for Gemini.
    const samples = Buffer.alloc(480);
    for (let i = 0; i < 240; i++) samples.writeInt16LE(Math.round(6000 * Math.sin(i / 8)), i * 2);
    const header = Buffer.from('524946460000000057415645666d74201000000001000100c05d000080bb0000020010006461746100000000', 'hex');
    header.writeUInt32LE(36 + samples.length, 4);
    header.writeUInt32LE(samples.length, 40);
    return json(200, {audio_base64: Buffer.concat([header, samples]).toString('base64'), mime_type: 'audio/wav'});
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
