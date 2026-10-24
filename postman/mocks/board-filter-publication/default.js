// Contract fixture for Flowcy's artifact prepare / S3 PUT / finalize API.
// No production credentials or storage are used.
const http = require('node:http');
const { createHash, randomUUID } = require('node:crypto');
const uploads = new Map();
const published = new Map();
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
http.createServer((req, res) => {
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const url = new URL(req.url, 'http://localhost');
    const reply = (status, value) => { res.writeHead(status, {'Content-Type':'application/json'}); res.end(JSON.stringify(value)); };
    if (url.pathname.startsWith('/storage/')) {
      if (req.headers.authorization || req.headers.cookie) return reply(403, {error:'Credentials leaked to S3'});
      const entry = uploads.get(url.pathname.split('/').pop());
      if (!entry || req.method !== 'PUT') return reply(404, {error:'Upload missing'});
      if (digest(body) !== entry.moduleHash || body.length !== entry.byteLength) return reply(400, {error:'Hash mismatch'});
      entry.uploaded = true;
      return reply(200, {});
    }
    if (!req.headers.authorization) return reply(401, {error:'Unauthorized'});
    const key = req.headers.authorization + url.pathname.replace(/\/(artifact|results)$/, '');
    if (url.pathname.endsWith('/results')) {
      const entry = published.get(key);
      return entry ? reply(200, {sourceHash:entry.sourceHash,moduleHash:entry.moduleHash,abiVersion:1})
        : reply(409, {error:'Publish the current source.',code:'artifact_required'});
    }
    if (!url.pathname.endsWith('/artifact')) return reply(501,{error:'Outside contract'});
    let input; try { input = JSON.parse(body); } catch { return reply(400,{error:'Invalid JSON'}); }
    if (req.method === 'POST') {
      if (input.abiVersion !== 1 || input.revision !== 2) return reply(409,{error:'Stale revision'});
      const id = randomUUID(); uploads.set(id, {...input,key});
      return reply(200,{uploadID:id,url:`http://127.0.0.1:4914/flowcy/storage/${id}`,method:'PUT',headers:{'content-type':'application/wasm'}});
    }
    if (req.method === 'PUT') {
      const entry = uploads.get(input.uploadID);
      if (!entry?.uploaded || entry.key !== key || url.searchParams.get('sourceHash') !== entry.sourceHash || url.searchParams.get('revision') !== '2') return reply(409,{error:'Invalid publication'});
      published.set(key,entry);
      return reply(200,{sourceHash:entry.sourceHash,moduleHash:entry.moduleHash,abiVersion:1,viewRevision:2});
    }
    reply(501,{error:'Outside contract'});
  });
}).listen(process.env.PORT || 4914);
