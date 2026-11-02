# session-resume

Bring coding-agent sessions back after a Rex server restart or a reboot.

Rex (0.1.0-preview.11 and later) restores sessions, windows and splits, but each pane comes back
as a fresh shell in its old directory. Whatever was running is gone. Claude Code, Codex and
OpenCode all save their conversations to disk and can reopen one by ID. The only missing piece is
remembering which conversation was open in which pane, and in which agent.

## Layout

```
bin/session-resume         record/forget state; shared by every plugin
plugins/<agent>/plugin.lua how the resume script relaunches this agent
plugins/claude/hooks.json  merge into ~/.claude/settings.json
plugins/codex/hooks.json   copy to ~/.codex/hooks.json, then trust it with /hooks
plugins/opencode/session-resume.js  copy to ~/.config/opencode/plugins/
```

`bin/session-resume` must be on `PATH`.

State is kept per agent, in `~/.local/state/session-resume/<agent>/<block-id>`, with the block ID
taken from `$REX_BLOCK`. Each file holds `key=value` lines:

```
session_id=…
cwd=…
```

Nothing is written outside Rex, when `$REX_BLOCK` is unset.

## Plugins

A plugin is a directory under `plugins/`, named after the agent. It has two jobs:

- **Hook into the agent** so it calls `session-resume record <agent> <id> <cwd>` when a
  conversation starts, and `session-resume forget <agent>` when you quit on purpose. Agents
  whose hooks send Claude-style JSON on stdin can call `session-resume hook <agent>` instead.
- **Say how to resume.** `plugin.lua` returns `{ name = …, resume = function(state) … end }`,
  where `resume` turns the parsed state file into an argv list.

| Agent    | Record                                   | Forget                                   | Resume                    |
| -------- | ---------------------------------------- | ---------------------------------------- | ------------------------- |
| claude   | `SessionStart` hook                      | `SessionEnd`, reason `prompt_input_exit` or `logout` | `claude --resume <id>`    |
| codex    | `SessionStart` hook                      | never (reason is always `other`)         | `codex resume <id>`       |
| opencode | `session.created`, then each `session.idle` | never (no exit event)                 | `opencode --session <id>` |

## How it works

1. **Record.** The agent's plugin writes the conversation ID and directory to its state file.
   `/clear` starts a new ID and `--resume` may too, so it overwrites the file every time.
   OpenCode fires no event when it resumes with `--session`, so its plugin records again each
   time the session goes idle.
2. **Forget.** Where the agent says why it is ending, the file is deleted only on a deliberate
   quit. A reboot sends SIGTERM, which may still run Claude's `SessionEnd` with reason `other`;
   the file is kept then. Codex and OpenCode can't tell a quit from a kill, so their files stay
   until the next resume pass. The resume list is what filters those out.
3. **Resume.** After the server starts, a Rex Lua script lists every block. For each
   `<agent>/<block-id>` file whose block still exists, it loads `plugins/<agent>/plugin.lua` and
   runs the argv from `resume` in that pane. The record step writes a fresh file once the agent
   starts.

Files whose block no longer exists are older than the last restore. Delete them on the same pass.
A block can only run one agent at a time, so if it has files for several agents, offer the newest.

## Open questions

- **Do block IDs survive a restore?** The changelog promises the same session IDs, and a test
  confirmed it. It doesn't say whether block IDs are kept too. If they aren't, key the files on
  session ID plus each pane's position in the layout instead.
- **How does the script run at startup?** Look for a server-start event in the Lua docs
  (`reference/events`, `automate/lua-events`). Otherwise, `rex.every` could check once and stop.
  As a fallback, a systemd user unit that runs after the server is up could use `rex send`.
- **Which `SessionEnd` reason does a kill give?** Send a test session SIGTERM and SIGHUP (Rex
  closing the pty) and log the reason, to check that step 2 really keeps the file.
- **Does Codex's `SessionStart` fire for subagents in the parent's hook?** Its docs say it runs
  when "a session or subagent starts". If a subagent shares `$REX_BLOCK`, it would overwrite the
  main conversation's ID. Check whether the payload marks subagents.
- **OpenCode event shapes.** The plugin reads `properties.info.id` and `info.parentID` from
  `session.created`, and `properties.sessionID` from `session.idle`. These are untested.
- **JSON parsing.** `session-resume hook` pulls fields out with `sed` to avoid needing `jq`. A
  `cwd` with an escaped quote in it will be cut short.
- **Is the shell ready?** Typing into a pane before zsh has drawn its prompt can lose the input.
  Wait for the prompt, or start the command with `rex run` in the restored block.
- **Should it ask first?** Resume everything automatically, or print a list and let you choose.
  Start with the list.

## Not in scope

- Programs that aren't coding agents with a resume-by-ID command. Rerunning arbitrary commands
  can have side effects (see the Rex "Layout restore" thread).
- Scrollback, which Rex doesn't restore yet. The community tool `rexurrect` does.
