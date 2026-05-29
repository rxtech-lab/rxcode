# MCP 与 ACP 客户端

RxCode 通过两种协议接入外部工具：用于工具服务器的 Model Context Protocol（MCP）和用于第三方编码代理的 Agent Client Protocol（ACP）。

## MCP 服务器

MCP 服务器为已安装的代理提供工具、资源和提示词。RxCode 读取、写入、探测并复用底层 CLI 代理的配置，因此在 RxCode 中添加的服务器也可被 Claude Code 和 Codex 使用。

### 添加服务器

打开 **设置 -> MCP**，点击 **添加服务器**，填写：

- **名称** — 代理使用的唯一标识。
- **范围** — `用户` 全局可用，`项目` 仅在当前工作目录生效。
- **传输方式** — 本地命令选 `stdio`，远程接入选 `http` 或 `sse`。

stdio 需要提供 **命令**（例如 `npx`），每行一个 **参数**。HTTP 传输需提供 **URL** 以及鉴权所需的 **请求头**。

### 环境变量

stdio 服务器以子进程方式运行，可通过 **环境** 编辑器逐服务器设置环境变量，例如 `OPENAI_API_KEY` 或 `GITHUB_TOKEN`。这些密钥仅保存在本机。

### 探测与工具列表

保存后 RxCode 会探测服务器、固定配置并列出可用工具。状态指示器显示 `connected`、`disconnected` 或错误。可通过开关启用或停用某个服务器而无需删除。

### 项目覆盖

选择项目后可以在 MCP 标签页对用户级服务器进行覆盖。常见用法是在某个仓库中禁用全局服务器或替换凭据。

## ACP 客户端

Agent Client Protocol 让 RxCode 接入 Claude Code 和 Codex 之外的代理，例如 OpenCode、Gemini CLI 等。

### 从注册表安装

打开 **设置 -> ACP 客户端 -> 注册表**。RxCode 会从 `cdn.agentclientprotocol.com` 获取官方注册表，按版本、许可证和简介列出每个代理。

点击 **添加** 即可安装。RxCode 会把对应平台的二进制分发包下载到：

```
~/Library/Application Support/RxCode/acp-binaries/<id>/<version>/
```

如果该代理没有 macOS 二进制分发，RxCode 会回退到注册表声明的 `npx` 或 `uvx` 包。

### 模型

安装后 RxCode 通过 ACP 探测代理对外公开的模型列表。若代理没有提供模型选择器，模型菜单只显示一个 **Default**，由代理在运行时自行决定模型。可在编辑器中点击 **Fetch** 重新探测。

### 环境

编辑客户端可以注入额外的环境变量，例如代理所需的 API 密钥。

### 启停与移除

通过开关启停某个客户端是否参与新对话。移除会从磁盘删除已安装的二进制及其配置。

## 何时使用

- **MCP** 为所有代理增加新工具。
- **ACP** 增加新的代理后端，后端本身也能使用 MCP 工具。

两者互补：先安装 ACP 客户端获得新代理，再用 MCP 服务器为其扩展工具能力。
