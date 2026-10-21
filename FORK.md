# fxh

fxh is a fork of [vercel-labs/fx](https://github.com/vercel-labs/fx), the coding agent by Vercel, made for the [Chaos Monkey Benchmark for Coding Agents](https://github.com/davila7/chaos-monkey-coding-agents). It is not made, endorsed, or supported by Vercel. "fx" is used here only to describe where the code comes from.

The fork adds one feature to fx 0.0.13: command hooks that run before and after the agent's built-in tool calls. Everything else, including the system prompt, tool names, tool descriptions, and error texts, is unchanged.

## Upstream base

- Upstream tag: `v0.0.13`, commit `4d966e272cfc4296cdf703f409480088cf2e72ba`.
- Branch: `cmca/v0.0.13`.
- Built from that tag with Zig 0.16.0 and `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux`, the upstream code produces a binary byte-identical to the published fx 0.0.13 linux x86_64 release (sha256 `00def23f9c68ef538d7d967394c3491910793461884fad0b983cb74011b9120c`).

## Changes

Every modified file carries a `Modified for fxh` notice on its first line.

| File | Change |
|---|---|
| `src/core/hooks/definitions.zig`, `runtime.zig`, `hooks.zig`, `tool.zig` | New `PostToolUse` hook kind. New `fail` action for `PreToolUse`. |
| `src/core/agent/runtime/lifecycle.zig` | `applyPostToolUse`; `fail` becomes a plain tool failure result. |
| `src/core/agent/runtime/orchestrator.zig`, `parallel_execution.zig` | Run `PostToolUse` after sequential and parallel tool calls. |
| `src/builtins/command_hooks.zig` (new) | Reads command hooks from settings and runs them. |
| `src/core/cli/cli_ask.zig`, `src/builtins/hooks/notifications.zig`, `src/acp/server.zig`, `src/main.zig` | Register command hooks in `fx ask`, the interactive app, and ACP. |
| `build.zig` | `-Dtest-filter` option. |
| `build.zig.zon` | Package name `fxh` and a new fingerprint, as Zig requires for forks. |
| `.github/workflows/fxh-release.yml` (new), `full-ci.yml` | Fork release build; upstream full CI skips `cmca/**` branches. |

The binary still reports version `0.0.13` and sends the `fx/0.0.13` user agent, so requests to the model provider are the same as fx 0.0.13's. The release archive names the binary `fxh`.

## Command hooks

Command hooks are set in the `hooks` key of the user settings file, `~/.fx/settings.json`, in the shape Claude Code uses:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "shell|read_file", "hooks": [ { "type": "command", "command": "/path/to/check", "timeout": 30 } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "/path/to/filter" } ] }
    ]
  }
}
```

- `matcher` is optional. Missing, empty, or `*` matches every tool. Otherwise it is a list of exact tool names separated by `|`. Regular expressions are not supported.
- Only `"type": "command"` is implemented. Other types are skipped.
- `timeout` is in seconds, default 60.
- Commands run with `/bin/sh -c` in the workspace directory. Only the user settings file is read; a workspace `.fx/settings.json` cannot add hooks.
- Hooks fire for local tool calls: built-in tools (`read_file`, `write_file`, `edit_file`, `grep_files`, `glob_files`, `shell`, and the rest) and MCP tools. Calls the model provider runs itself do not fire hooks.
- Hooks run in `fx ask`, the interactive app, and ACP sessions.

### Input

Each command receives one JSON object on stdin.

| Field | Events | Value |
|---|---|---|
| `hook_event_name` | both | `PreToolUse` or `PostToolUse` |
| `session_id` | both | fx session id, or null |
| `cwd` | both | workspace directory |
| `tool_name` | both | fx tool name |
| `tool_input` | both | the call's arguments object |
| `tool_use_id` | both | the call id |
| `agent_id` | both | subagent id, only inside a subagent |
| `tool_response` | `PostToolUse` | the tool result text as the model would see it |

### PreToolUse output

- Exit code 2 refuses the call. Trimmed stderr is the failure message the model sees.
- Exit code 0 with `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..."}}` refuses the call with that message.
- Exit code 0 with `hookSpecificOutput.updatedInput` (an object) replaces the call's arguments.
- A refused call does not run. The model gets a failed tool result in fx's standard failure shape, `{"error":{"type":"tool_execution_failed","tool_name":...,"message":...}}`, with the hook's message and no extra retry guidance.
- Hooks run before fx's permission checks, so a hook can refuse a call but cannot let through a call that fx's permission rules refuse.

### PostToolUse output

`PostToolUse` runs only after a call that succeeded.

- Exit code 0 with `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": "..."}}` replaces the result the model sees. A non-string value is sent as JSON text.
- fxh extension: `"updatedToolOutputIsError": true` next to `updatedToolOutput` makes the result a failed call, in fx's standard failure shape with the given text as the message. Claude Code's hook output has no field for this.
- A replaced result drops fx's stored preview and replay handle for the original output.

### Failures

A command that cannot start, exits with another code, times out, is killed by a signal, or prints output that is not the JSON above leaves the call unchanged. The reason is written to fx's trace log.

## Upstream

No change from this fork has been offered to vercel-labs/fx. An offer would be a separate port onto fx `main`.

## License

Apache License 2.0, as upstream; see `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES.md`.
