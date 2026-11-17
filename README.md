# session-resume

Bring coding-agent sessions back after a Rex server restart or a reboot.

Rex (0.1.0-preview.11 and later) restores sessions, windows and splits, but each pane comes back
as a fresh shell in its old directory. Whatever was running is gone. Coding agents save their
conversations to disk and can reopen one by ID. The only missing piece is remembering which
conversation was open in which pane.

## Supported harnesses

- [x] **Claude Code**: `SessionStart` and `SessionEnd` hooks, resumed with `claude --resume <id>`
- [ ] **Codex CLI**: Codex windows share an app-server daemon, which keeps the `$REX_BLOCK` of
      whichever pane started it. If hooks run inside it, every Codex session would be recorded
      under that one pane. Check this first.
- [ ] **OpenCode**: needs a plugin that records on `session.created` and `session.idle`. It has
      no exit event, so its records can't be forgotten on a deliberate quit.

Adding a harness means an entry in `resume_cmd` in `lib/session-resume.lua`, plus hooks that call
`session-resume hook <agent>` with a Claude-style JSON payload.

## Install

Requires only the `rex` CLI. session-resume is written in Lua and runs on Rex's own Lua with
`rex do`, so there's nothing to build and no other runtime. `bin/session-resume` is a few lines
of `sh` that pass the command line through, since `rex do` only takes `KEY=VALUE` arguments.

```sh
git clone https://github.com/qstearns/session-resume ~/src/session-resume
ln -s ~/src/session-resume/bin/session-resume ~/.local/bin/
session-resume setup
```

Like `rex skill setup`, `setup` installs two small pieces that point back at the command, so
updating the checkout updates what they do:

- **Claude Code:** a plugin folder at `~/.claude/skills/session-resume`. Claude Code loads any
  plugin folder there on its own, as `session-resume@skills-dir`, with no marketplace and no
  edit to `settings.json`. It holds the `SessionStart` and `SessionEnd` hooks and the `recover`
  skill, whose instructions come from `session-resume skill recover`.
- **Rex:** a marked block in `~/.config/rex/init.lua` that launches `session-resume autostart`
  in the background whenever the config loads. Rex has no folder for drop-in config, so this is
  the only edit to a file you own.

Both use absolute paths, because the Rex server starts at login without your shell's `PATH`.
Run `setup` again if you move the checkout. `session-resume status` shows what's installed and
whether it's current, and `session-resume remove` takes both out again. Restart running Claude
Code sessions after the first setup to load the hooks.

## Use

Nothing, normally. When the Rex server starts, `autostart` waits until Rex has finished restoring
sessions and the panes' shells are up. Then it resumes every `resume` record without asking. It
logs what it did to `~/.local/state/session-resume/autostart.log`.

`init.lua` also runs on every `rex config reload`. Autostart remembers the server's
`instance_id`, which changes only when the server restarts, so a reload does nothing.

To restore by hand instead:

```sh
session-resume restore
```

It lists every record and what it will do with it, then asks before typing anything:

| Status      | Meaning                                    | Restore does |
| ----------- | ------------------------------------------ | ------------ |
| `resume`    | The pane exists and sits at a shell prompt | Resumes it   |
| `running`   | The pane already runs that agent           | Nothing      |
| `busy`      | The pane runs something else               | Nothing      |
| `duplicate` | A newer record names the same conversation | Deletes it   |
| `orphan`    | The pane is gone                           | Nothing      |

Orphans are left for you to sort out. Run `/session-resume:recover` in Claude Code: it lists
each one with what it was about and where it was, then asks whether to resume it in a new tab or
split, drop it, or leave it.

`session-resume list [--json]` shows the same plan without doing anything.

## How it works

State is one JSON file per pane, in `~/.local/state/session-resume/<block-id>.json`:

```json
{ "agent": "claude", "session_id": "…", "cwd": "…", "rex_session": "session:…",
  "rex_block": "block:…", "updated_at": "…" }
```

1. **Record.** Every `SessionStart` (startup, resume, `/clear`, compact) rewrites the pane's
   record, since `/clear` and `--resume` can change the ID. It's skipped when the agent isn't the
   pane's foreground program, so a `claude -p` run from inside a pane, which inherits
   `$REX_BLOCK`, doesn't overwrite it. Nothing is written outside Rex.
2. **Forget.** `SessionEnd` deletes the record only when you quit on purpose (reason
   `prompt_input_exit` or `logout`) and only if the record still names that conversation. A
   reboot or a closed pane leaves it.
3. **Restore.** `session-resume restore` matches records to live panes by block ID and types
   `cd <cwd> && claude --resume <id>` into each idle one. The agent then records itself again.

Rex keeps block IDs across a server restart, so records find their panes again. A record whose
pane is gone becomes an orphan, usually because the pane was closed while its agent was running.
Rather than guess where it belongs, restore leaves it to `/session-resume:recover`.

## Open questions

- **Which `SessionEnd` reason does a kill give?** Send a test session SIGTERM and SIGHUP (Rex
  closing the pty) and log the reason, to check that step 2 really keeps the record.
- **A real server-start event.** Rex has no `server_started` event, and `rex.on` doesn't work in
  `init.lua`, so autostart polls until restore settles. A Rex event would replace the polling.

## Not in scope

- Programs that aren't coding agents with a resume-by-ID command. Rerunning arbitrary commands
  can have side effects (see the Rex "Layout restore" thread).
- Scrollback, which Rex doesn't restore yet. The community tool `rexurrect` does.
