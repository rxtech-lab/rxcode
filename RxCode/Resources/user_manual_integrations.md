# MCP and ACP Clients

RxCode connects to external tooling through two protocols: the Model Context Protocol (MCP) for tool servers, and the Agent Client Protocol (ACP) for third-party coding agents.

## MCP Servers

Model Context Protocol servers expose tools, resources, and prompts that any installed agent can call. RxCode reads, writes, probes, and shares the same configuration that the underlying CLI agents read, so a server added in RxCode is also available to Claude Code and Codex.

### Adding a Server

Open **Settings -> MCP** and click **Add Server**. Fill in:

- **Name** — a unique identifier used by the agent.
- **Scope** — `user` makes the server available in every project, `project` scopes it to the current working directory.
- **Transport** — choose `stdio` for local commands, `http` or `sse` for remote endpoints.

For stdio transports, provide a **Command** (for example `npx`) and one **Arg** per line. For HTTP transports, provide the server **URL** and any **Headers** required for authentication.

### Environment Variables

Stdio servers run as child processes. Use the **Environment** editor to set per-server environment variables — for example `OPENAI_API_KEY` or `GITHUB_TOKEN`. Secrets stay on this machine.

### Probing and Tool Lists

After save, RxCode probes the server, pins the configuration, and lists available tools. The status indicator shows `connected`, `disconnected`, or an error. Toggle the row to enable or disable a server without removing it.

### Project Overrides

User-scope servers can be overridden per project from the same MCP tab when a project is selected. Use overrides to disable a global server in one repository or to swap credentials.

## ACP Clients

The Agent Client Protocol lets RxCode talk to additional coding agents besides Claude Code and Codex. Examples include OpenCode and Gemini CLI.

### Installing From the Registry

Open **Settings -> ACP Clients -> Registry**. RxCode fetches the official registry from `cdn.agentclientprotocol.com` and lists each agent with version, license, and a short description.

Click **Add** to install. RxCode downloads the platform-specific binary distribution into:

```
~/Library/Application Support/RxCode/acp-binaries/<id>/<version>/
```

If a binary distribution is not available for macOS, RxCode falls back to `npx` or `uvx` packages declared in the registry.

### Models

After install, RxCode probes the client over ACP to discover the models it advertises. If the agent does not expose a model selector, the picker shows a single **Default** entry and the agent picks its own model at runtime. Click **Fetch** in the editor sheet to retry the probe.

### Environment

Edit a client to inject extra environment variables — for example API keys required by the agent.

### Enable and Remove

Toggle the row to enable or disable a client for new threads. Remove deletes the installed binary from disk along with the configuration.

## When to Use Which

- **MCP** adds new tools to every agent.
- **ACP** adds new agents that can themselves use MCP tools.

The two are complementary: install an ACP client to gain a new agent backend, then add an MCP server to expose extra tools to it.
