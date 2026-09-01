# PSOpenCode

PSOpenCode is a minimal, unofficial coding-agent CLI written entirely in
PowerShell 7. It has no executable, SDK, module, or package dependencies.

It talks directly to GitHub Copilot over HTTPS and includes:

- device login through `microsoft.ghe.com` and your Microsoft Entra credentials
- encrypted local credential storage on Windows
- model discovery for the models enabled on your Copilot account
- streaming responses, reasoning output, and OpenAI-compatible tool calling
- OpenCode-style build and plan modes
- local file listing, reading, searching, writing, exact replacement, and
  PowerShell execution tools
- interactive approval for mutating tools

> GitHub does not publish a supported Copilot inference API. The Copilot token,
> model, and chat endpoints used here are undocumented and can change or be
> blocked. The OAuth device flow itself is documented by GitHub.

## Requirements

- PowerShell 7+
- access to `microsoft.ghe.com`
- a GitHub Copilot entitlement

No `copilot.exe`, `gh.exe`, Node.js, Python, .NET SDK, or other executable is
used.

## Project layout

| File | Responsibility |
| --- | --- |
| `psopencode.ps1` | CLI parameters, startup, and interactive prompt loop |
| `src/Common.ps1` | Shared property and HTTP helpers |
| `src/Auth.ps1` | Device login and encrypted credential storage |
| `src/Copilot.ps1` | Copilot connection, headers, and model discovery |
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

Inside the interactive UI, use `/mode` to toggle modes or `/mode build` and
`/mode plan` to select one explicitly. Other commands are `/models`,
`/model <id> [reasoning]`, `/new`, `/help`, and `/exit`. The `/models` table
lists each model's selectable reasoning modes. For example:

```text
/model claude-opus-4.8 xhigh
```

PSOpenCode is inspired by [OpenCode](https://github.com/anomalyco/opencode), but
is not affiliated with the OpenCode project.
