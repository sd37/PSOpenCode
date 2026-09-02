# PSOpenCode

PSOpenCode is a minimal, unofficial coding-agent CLI written entirely in
PowerShell 7. It has no executable, SDK, module, or package dependencies.

It talks directly to GitHub Copilot over HTTPS and includes:

- device login through `microsoft.ghe.com` and your Microsoft Entra credentials
- encrypted local credential storage on Windows
- model discovery for the models enabled on your Copilot account
- streaming responses, reasoning output, and OpenAI-compatible tool calling
- OpenCode-style build and plan modes
- session-selectable remote MCP servers over Streamable HTTP
- local file listing, reading, searching, writing, exact replacement, and
  PowerShell execution tools
- interactive approval for mutating tools

> GitHub does not publish a supported Copilot inference API. The Copilot token,
> model, and chat endpoints used here are undocumented and can change or be
> blocked. The OAuth device flow itself is documented by GitHub.

## Requirements

- PowerShell 7+ running in `FullLanguage` mode
- access to `microsoft.ghe.com`
- a GitHub Copilot entitlement

`ConstrainedLanguage` mode is not supported because PSOpenCode requires .NET
networking, streaming, cryptography, and secure credential APIs. In managed
environments, have an administrator approve or trust the PSOpenCode scripts so
the organization policy permits them to run in `FullLanguage` mode.

No `copilot.exe`, `gh.exe`, Node.js, Python, .NET SDK, or other executable is
used.

## Project layout

| File | Responsibility |
| --- | --- |
| `psopencode.ps1` | CLI parameters, startup, and interactive prompt loop |
| `src/Common.ps1` | Shared property and HTTP helpers |
| `src/Auth.ps1` | Device login and encrypted credential storage |
| `src/Copilot.ps1` | Copilot connection, headers, and model discovery |
| `src/McpAuth.ps1` | MCP OAuth discovery, device login, refresh, and DPAPI cache |
| `src/McpTransport.ps1` | MCP Streamable HTTP and JSON-RPC transport |
| `src/Mcp.ps1` | MCP configuration, selection, tools, and results |
| `src/Streaming.ps1` | Streaming chat and reasoning deltas |
| `src/Tools.ps1` | Native workspace tools and approval checks |
| `src/Agent.ps1` | Agent loop, modes, and conversation history |

## Login

Run the script:

```powershell
pwsh ./psopencode.ps1
```

When no saved login exists, the script automatically prints a
`microsoft.ghe.com/login/device` URL and code. Open the URL, enter the code, and
authenticate using your organization’s Microsoft credentials. After
authorization, the available Copilot model list is printed and the interactive
prompt starts.

The GitHub token is encrypted using Windows DPAPI under
`$HOME\.psopencode`. To use a non-persisted token instead:

```powershell
$env:PSOPENCODE_GITHUB_TOKEN = 'YOUR_TOKEN'
```

Log out and delete the stored token:

```powershell
pwsh ./psopencode.ps1 -Logout
```

Force a fresh interactive login:

```powershell
pwsh ./psopencode.ps1 -Login
```

## Usage

```powershell
# List models enabled for the authenticated account
pwsh ./psopencode.ps1 -ListModels

# Interactive coding session
pwsh ./psopencode.ps1

# Read-only exploration and implementation planning
pwsh ./psopencode.ps1 -Mode plan

# One-shot prompt
pwsh ./psopencode.ps1 -Model gpt-5.4 'Explain this repository'

# Allow file changes and commands without confirmation
pwsh ./psopencode.ps1 -AutoApprove

# Allow file tools to access absolute paths outside the selected workspace
pwsh ./psopencode.ps1 -AllowOutsideWorkspace

# Chat without local coding tools
pwsh ./psopencode.ps1 -NoTools
```

The default **build** mode exposes all coding tools. **Plan** mode exposes only
workspace exploration tools, removes file mutation tools, and always asks
before running PowerShell even when `-AutoApprove` is set.

`claude-opus-4.8` is the default model, with reasoning effort set to `max`.
Reasoning-capable models stream a dimmed `Thinking:` section followed by the
response as it is generated. Override these defaults with `-Model` and
`-ReasoningEffort`. The banner, input prompt, and `/model` confirmation show the
effective reasoning level.

## MCP servers

`mcp.json` contains entries for `ado`, `workiq`, `bluebird`, `icm`, `enghub`,
`s360-breeze`, `teams`, `sharepoint`, and `github-mcp-server`. PSOpenCode
discovers OAuth metadata from each selected server, starts its configured OAuth
login flow, refreshes Copilot and MCP tokens before they expire during long-running
sessions, and stores tokens using Windows DPAPI under `$HOME\.psopencode`. It
cannot reuse tokens owned by another MCP host.

GitHub's public endpoint is configured directly. Azure DevOps uses its standard
endpoint and prompts once for the organization name:

```powershell
# Prompts for the ADO organization, then performs OAuth device login
pwsh ./psopencode.ps1 -Mcp ado

# GitHub performs OAuth device login without a token parameter
pwsh ./psopencode.ps1 -Mcp github-mcp-server

# Select specific servers after their endpoints are configured
pwsh ./psopencode.ps1 -Mcp ado,workiq

# Connect to the Microsoft 365 Teams and SharePoint servers
pwsh ./psopencode.ps1 -Mcp teams,sharepoint

# Select every configured server
pwsh ./psopencode.ps1 -Mcp all
```

Azure DevOps and GitHub do not advertise dynamic OAuth client registration.
GitHub uses PSOpenCode's embedded public device-flow client ID. For Azure DevOps,
PSOpenCode prompts once for a public-client application ID registered by you or
your administrator; a client ID is not a secret. The other built-in servers use
verified endpoints, advertised OAuth scopes, and public OAuth client IDs.
WorkIQ and Bluebird use device login. IcM, EngHub, S360 Breeze, Teams, and
SharePoint use browser authorization with a loopback PKCE callback. EngHub,
S360 Breeze, Teams, and SharePoint use this flow to satisfy Conditional Access
and authorize against Microsoft's home tenant directly. An MCP entry can set
`auth.authorizationServer` when a server's advertised generic authority cannot
authorize its tenant-restricted resource.

Use `-McpConfig <path>` to load another configuration. Set `auth.type` to
`oauth`, with optional `clientId` and `scopes`. If the authorization server
advertises dynamic client registration, PSOpenCode uses it when `clientId` is
omitted. Static `headers` remain supported as an override. Header values and
URLs support `${ENVIRONMENT_VARIABLE}` placeholders; missing non-secret values
are requested interactively and remembered in
`$HOME\.psopencode\mcp-settings.json`.

Inside an interactive session, `/mcps` shows configured servers and their
status. `/mcp ado`, `/mcp ado on`, and `/mcp ado off` change the current
selection without restarting. Only tools from selected, successfully connected
servers are sent to the model. MCP tool calls use the normal approval prompt;
`-AutoApprove` bypasses it only in build mode. Plan mode exposes only MCP tools
that advertise `readOnlyHint: true`, and still asks before each call.

Inside the interactive UI, use `/mode` to toggle modes or `/mode build` and
`/mode plan` to select one explicitly. Other commands are `/models`,
`/model <id> [reasoning]`, `/mcps`, `/mcp <name> [on|off]`, `/new`, `/help`,
and `/exit`. The `/models` table lists each model's selectable reasoning modes.
For example:

```text
/model claude-opus-4.8 xhigh
```

PSOpenCode is inspired by [OpenCode](https://github.com/anomalyco/opencode), but
is not affiliated with the OpenCode project.
