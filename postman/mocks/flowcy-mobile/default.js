// Contract fixtures derived from github-pm/lib/mcp and the mobile NDJSON route.
// This server is a local simulator dependency; it is never bundled in the app.
const http = require('http');
let notificationDevice = null;
http.createServer(async (req, res) => {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  const json = (status, value) => { res.writeHead(status, {'Content-Type':'application/json'}); res.end(JSON.stringify(value)); };
  if (!req.headers.authorization || req.headers.authorization === 'Bearer expired') return json(401, {error:'Unauthorized'});
  const path = new URL(req.url, 'http://simulation.local').pathname;
  if (req.method === 'GET' && path.endsWith('/api/v1/docs/repositories')) {
    if (req.headers.authorization === 'Bearer project-error') return json(503, {error:'Projects temporarily unavailable'});
    if (req.headers.authorization === 'Bearer slow-projects') await new Promise(resolve => setTimeout(resolve, 500));
    return json(200, {items:[{id:'project',name:'Cloud Project'}],pagination:{hasMore:false}});
  }
  if (req.method === 'GET' && path.endsWith('/api/v1/docs/repositories/project/tasks')) {
    if (req.headers.authorization === 'Bearer slow-board') await new Promise(resolve => setTimeout(resolve, 500));
    return json(200, {stories:[],tasks:[{id:'task',title:'Loaded task'}]});
  }
  if (req.method === 'GET' && path.endsWith('/api/v1/devices')) return json(200, []);
  if (req.url.endsWith('/api/v1/simulation/rejected-feature')) return json(401, {error:'Account bearer not supported by this deployment'});
  if (req.url.endsWith('/api/v1/notifications/devices')) {
    const body = req.body ?? (raw ? JSON.parse(raw) : {});
    if (req.method === 'PUT') {
      if (!body.id || body.provider !== 'apns' || !/^[a-f0-9]{64,200}$/i.test(body.token)) return json(400, {error:'Invalid device registration'});
      notificationDevice = {id:body.id,name:body.name,provider:body.provider,environment:body.environment};
      return json(200, {id:body.id});
    }
    if (req.method === 'GET') return json(200, notificationDevice ? [notificationDevice] : []);
    if (req.method === 'DELETE') {
      if (notificationDevice?.id === body.id) notificationDevice = null;
      res.writeHead(204); return res.end();
    }
    return json(501, {error:'Outside simulation contract'});
  }
  if (req.url.endsWith('/api/v1/agent/tools')) {
    const body = req.body ?? JSON.parse(raw);
    if (body.method === 'notifications/initialized') { res.writeHead(202); return res.end(); }
    let result;
    if (body.method === 'initialize') result = {protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'Flowcy simulation',version:'1'}};
    else if (body.method === 'tools/list') result = {tools:[{name:'list_tasks',description:'List authorized project tasks',inputSchema:{type:'object',properties:{repoId:{type:'string'}}}},{name:'create_task',description:'Create a task',inputSchema:{type:'object',properties:{repoId:{type:'string'},title:{type:'string'}}}}]};
    else if (body.method === 'tools/call') {
      if (body.params.arguments.repoId === 'denied') return json(403, {error:'Forbidden'});
      result = body.params.arguments.fail ? {isError:true,content:[{type:'text',text:'Permission denied'}]} : {content:[{type:'text',text:JSON.stringify({tasks:[],projectId:body.params.arguments.repoId})}]};
    } else return json(501, {error:'Outside simulation contract'});
    // MCP responses may use SSE, even when not streaming a model response.
    res.writeHead(200, {'Content-Type':'text/event-stream','Mcp-Session-Id':'simulation-session'});
    return res.end('event: message\ndata: '+JSON.stringify({jsonrpc:'2.0',id:body.id,result})+'\n\n');
  }
  if (req.method === 'POST' && path.endsWith('/api/v1/agent/draft')) {
    const body = req.body ?? (raw ? JSON.parse(raw) : {});
    if (body.projectId === 'denied') return json(404, {error:'Project not found'});
    if (body.prompt === 'model failure') return json(502, {error:'Could not generate a draft. Try again.'});
    if (!body.projectId || !['task','story'].includes(body.kind) || !body.prompt?.trim() || body.prompt.length > 8000)
      return json(400, {error:'Invalid draft request'});
    return json(200, {title:body.kind === 'story' ? 'Enable offline work' : 'Cache board data',details:'## Acceptance criteria\nBoard data remains available offline.'});
  }
  if (req.url.endsWith('/api/v1/agent/chat')) {
    res.writeHead(200, {'Content-Type':'application/x-ndjson'});
    const body = req.body ?? JSON.parse(raw);
    const messages = body.messages ?? [];
    const prompt = messages.findLast(m => m.role === 'user')?.content ?? '';
    const hasResult = messages.at(-1)?.role === 'tool';
    if (prompt.includes('Tool') && !hasResult) {
      res.write(JSON.stringify({type:'tool-call',id:'simulation-call',name:prompt.includes('Create') ? 'create_task' : 'list_tasks',arguments:{repoId:'authorized',title:'Simulation task'}})+'\n');
    } else res.write(JSON.stringify({type:'text',text:'**Actual simulated transport** ✓'})+'\n');
    return setTimeout(()=>res.end(JSON.stringify({type:'finish'})+'\n'),prompt.includes('Slow') ? 5000 : 100);
  }
  return json(501, {error:'Outside simulation contract'});
}).listen(process.env.PORT || 4913);
