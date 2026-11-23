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

Completed MCP tool calls can display an App inline in the transcript. RxCode
checks the originating server's tool metadata for `_meta.ui.resourceUri` or the
legacy `_meta["ui/resourceUri"]`, then reads the corresponding `ui://` resource.
Opening an App does not execute the original tool again. Select the tool row to
inspect its parameters and original result, including when an App cannot load.

Apps use a separate MCP connection over stdio or Streamable HTTP. Legacy SSE
transport is not supported by the App connection. RxCode prefers its native JSON
profile when the server offers both native JSON and HTML for the declared URI.

### Native JSON UI

Return a `resources/read` content item with the declared URI and the exact MIME
type `application/vnd.rxcode.ui+json;version=1`. Put the UTF-8 document in
`text`, or base64-encode it in `blob`. Its `root` and `elements` use the
existing native component catalog. A top-level `presentation` hint has no effect
on placement. A presentation element used as the root displays inline. A user
can still open a nested presentation with a button. See the [JSON UI catalog and form behavior](../architecture/json-ui.md).

The optional `bindings` object is keyed by submit Button element ID. Each binding
has a local `tool` name and an `arguments` object mapping argument names to input
names. An input name defaults to its element ID. Use an empty map for a tool
that takes no arguments. Only fields in the submit action's form scope can be
mapped. Unbound submits keep the form values local.

Clicking a bound button captures the current mapped JSON values. The host owns
the server and project identity, tool visibility checks, and user approval for
those arguments. The row displays the pending state and the resulting tool
output, denial, or error. Edits made during approval apply to the next submit.

The v1 limits are 512,000 document bytes, 64 JSON nesting levels, 300 elements
and 24 levels per element tree. Each element can have at most one parent.
The document's render budget is 4,096 items, counting elements, array-valued
property entries and table rows multiplied by columns. Detached trees count
toward the same limits.

The fixture includes the document, the expected tool call for its initial
values, and the tool response. Serialize its `document` member as the resource
body. [Weather form fixture](../fixtures/mcp-json-ui-v1.json)

### HTML

Use `text/html;profile=mcp-app` for HTML. Original tool arguments and results
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
