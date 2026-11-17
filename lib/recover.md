# Recover lost sessions

`session-resume` keeps one record per Rex pane. After Rex restores its sessions, `session-resume restore` reopens each conversation in its old pane. A record is an **orphan** when its pane no longer exists: Rex gave the pane a new ID, or the pane was closed while the agent was still running. Your job is to show the user the orphans and do what they decide for each one. Never resume or drop anything without asking.

Below, `session-resume` means the command you just ran to print these instructions. Use that same path if `session-resume` isn't on `PATH`.

## 1. Find the orphans

```sh
session-resume list --json | jq '[.[] | select(.status == "orphan")]'
```

Each record has `agent`, `session_id`, `cwd`, `rex_session` (the Rex session the pane was in), `rex_block` (the pane that's gone) and `updated_at`. If there are none, say so and stop.

## 2. Describe each one

For each orphan, work out enough for the user to recognise it:

- **What it was about.** For Claude, the transcript is `~/.claude/projects/*/<session_id>.jsonl`. Use its title if it has one (a `custom-title` or `summary` line), else the first real user message, shortened. If there's no transcript, the conversation can't be resumed; say so and suggest dropping it.
- **Where it was.** Look up `rex_session` in `rex ls --json`. Rex keeps session IDs across a restore, so it's often still there; use its label. Otherwise say the session is gone.
- **When**, from `updated_at`, as a relative time.
- **Whether it's already open.** If another record with status `resume` or `running` has the same `session_id`, it's a duplicate. Recommend dropping it.

Show them as a short numbered list, newest first.

## 3. Ask what to do

Ask once, covering every orphan (with AskUserQuestion when it's available). The choices for each one:

- **Resume in a new tab** in its old Rex session if that still exists, otherwise in the current session (`$REX_SESSION`).
- **Resume in a split** next to the user's current pane.
- **Drop** the record. This only deletes the record; the conversation stays on disk and `claude --resume` can still find it.
- **Leave it** for later.

If there are more than four orphans, ask for one choice that applies to all of them first, then ask about the exceptions.

## 4. Do it

Run `rex skill show` first if you haven't used Rex in this conversation.

Resume in a new tab. Name the tab after the cwd's last directory and don't rename anything else:

```sh
new=$(rex window new -s "$session" "$(basename "$cwd")" -c "$cwd" --focus=false --json | jq -r '.block_ids[0]')
session-resume resume "$rex_block" "$new"
```

Resume in a split:

```sh
new=$(rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right -c "$cwd" --focus=false --json | jq -r '.block_ids[0]')
session-resume resume "$rex_block" "$new"
```

`resume` types the agent's resume command into the new pane and drops the old record. The agent records itself under its new pane when it starts. Never resume into your own pane (`$REX_BLOCK`), or into a pane that isn't at a shell prompt; `resume` refuses those anyway.

Drop:

```sh
session-resume drop "$rex_block" ...
```

Finish with one line per orphan saying what happened, and run `session-resume list` to show what's left.
