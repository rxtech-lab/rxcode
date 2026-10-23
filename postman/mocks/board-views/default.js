// Contract: docs/project-board-views.md in the Flowcy backend.
const http = require("http");
http.createServer(async (req, res) => {
  const rawBody = new Promise(resolve => {
    let raw = "";
    req.on("data", chunk => raw += chunk);
    req.on("end", () => resolve(raw));
  });
  const reply = (status, value) => { res.writeHead(status, {"Content-Type": "application/json"}); res.end(JSON.stringify(value)); };
  const path = req.url.split("?")[0];
  if (!path.endsWith("/board-views")) return reply(501, {error: "Not modeled"});
  if (path.includes("/legacy/")) return reply(404, {error: "Not found"});
  if (!req.headers.authorization) return reply(401, {error: "Unauthorized"});
  const key = "rxcode-board-views:" + req.headers.authorization + ":" + path;
  const saved = await pm.state.get(key) || {views: [], revision: 0};
  if (req.method === "GET") return reply(200, saved);
  if (req.method === "PUT") {
    const body = JSON.parse(await rawBody);
    if (body.revision !== saved.revision) return reply(409, {error: "Views changed on another device. Refresh and retry."});
    const next = {views: body.views, revision: saved.revision + 1};
    await pm.state.set(key, next);
    return reply(200, next);
  }
  reply(501, {error: "Not modeled"});
}).listen(process.env.PORT || 4912);
