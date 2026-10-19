# MCP OAuth and Apps

## Authentication

In Settings → MCP Servers, open a remote server's menu and choose **Authentication…**.
Use **Sign In** to discover the authorization server and open the system authentication
browser. Supply a registered public OAuth client ID if the server does not support
dynamic registration. The redirect URI is `rxcode://mcp/oauth/callback`.

RxCode validates the resource and issuer, requires PKCE S256, and checks callback
state. Access and refresh tokens are stored in the macOS Keychain, keyed by the full
MCP resource URL. OAuth requests do not follow redirects. Remote endpoints must use
HTTPS; HTTP is accepted for loopback servers.

Credentials are refreshed before use and supplied to Claude Code, Codex, and ACP
clients when preparing their MCP configuration. They are not saved in the server
record. Generated Claude configuration files are restricted to the current user.
An already running agent receives updated credentials on its next launch; sign in
again if the service revokes access. **Sign Out…** removes local saved credentials;
it does not revoke the authorization grant at the provider.

## Apps

Open a completed MCP tool call's detail sheet and choose **Open MCP App**. RxCode
checks the originating server's tool metadata for `_meta.ui.resourceUri` or the
legacy `_meta["ui/resourceUri"]`, then reads the corresponding `ui://` resource.
Opening an App does not execute the original tool again. Tools without an App
continue to show their ordinary parameters and results.

Apps use a dedicated sheet and a separate MCP connection over stdio or Streamable
HTTP. Legacy SSE transport is not supported by the App connection. The resource
must have MIME type `text/html;profile=mcp-app`. Original tool arguments and results
are delivered after the App's initialization handshake. Structured results and
private result metadata are retained when supplied by the agent runtime.

HTML runs in an opaque-origin sandbox with an ephemeral WebKit data store. The
host enforces a restrictive content security policy and accepts declared HTTPS
origins from the resource content's `_meta.ui.csp`. Listing-only CSP defaults are
not used; undeclared access remains blocked. Navigation, forms, popups, and media
capture are blocked. Servers should return self-contained HTML or declare required
resource origins in their resource content metadata.

The host supports `ui/initialize`, `ui/notifications/initialized`, `ping`,
`tools/list`, and `tools/call`. Each App tool call requires native user confirmation,
can reach only its originating server, and must allow `app` visibility. Unsupported
requests receive a JSON-RPC error. Sampling, external links, downloads, and arbitrary
resource reads are not advertised or forwarded.

Protocol references: [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
and [MCP Apps](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/draft/apps.mdx).
