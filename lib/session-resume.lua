-- Remember which agent conversation is open in each Rex pane, and reopen them
-- after Rex restores its sessions.
--
--   session-resume setup              install the Claude Code plugin and the init.lua block
--   session-resume status             what's installed and whether it's current
--   session-resume remove             uninstall both
--   session-resume list [--json]      every record and what restore would do with it
--   session-resume restore [-y]       show the plan, ask, then resume in place
--   session-resume resume BLOCK [TO]  resume one record, in its pane or in pane TO
--   session-resume drop BLOCK...      delete records
--   session-resume skill NAME         print a skill's instructions (lib/NAME.md)
--   session-resume hook AGENT         called by the agent's hooks, payload on stdin
--   session-resume autostart          restore without asking; run by Rex at start
--
-- This runs under `rex do`, Rex's own Lua 5.1, started by bin/session-resume.
-- That shim passes the command line as arg1=:hook arg2=:claude ..., plus pid
-- (this process) and shim (its own path). One record per pane, in
-- $XDG_STATE_HOME/session-resume/<block-id>.json.

local json = rex.json

local function arg(k) local v = rex.args[k]; return v ~= nil and tostring(v):sub(2) or nil end
local argv = {}
for i = 1, 100 do
	local v = arg("arg" .. i)
	if v == nil then break end
	argv[i] = v
end
local self_pid = tonumber(rex.args.pid)

local state_root = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/session-resume"

local function die(msg)
	io.stderr:write("session-resume: " .. msg .. "\n")
	rex.stop(2)
end

local function now() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
local function shq(s) return "'" .. (s:gsub("'", "'\\''")) .. "'" end
local function prog(argv0) return (argv0 or ""):gsub("^%-", ""):match("[^/]*$") end

-- Supported harnesses: how to reopen a conversation by ID. Adding one means an
-- entry here plus hooks that call `session-resume hook <agent>`.
local resume_cmd = {
	claude = function(id) return "claude --resume " .. shq(id) end,
}

local SHELLS = {}
for _, s in ipairs({ "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "xonsh", "elvish" }) do SHELLS[s] = true end

local function check_block(b)
	if type(b) ~= "string" or not b:match("^block:[%w%-]+$") then die("bad block id: '" .. tostring(b) .. "'") end
end

-- --- records ------------------------------------------------------------------

local function record_path(b) return state_root .. "/" .. b .. ".json" end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function load_record(path)
	local ok, r = pcall(json.decode, read_file(path) or "")
	if ok and type(r) == "table" and r.session_id and r.rex_block then return r end
end

local function write_record(r)
	rex.exec({ "mkdir", "-p", state_root })
	local path = record_path(r.rex_block)
	local tmp = state_root .. "/." .. r.rex_block .. "." .. tostring(self_pid or os.time())
	local f = assert(io.open(tmp, "w"))
	f:write(json.encode(r), "\n")
	f:close()
	assert(os.rename(tmp, path))
end

local function records()
	local out = {}
	local r = rex.exec({ "find", state_root, "-maxdepth", "1", "-name", "block:*.json" })
	if not (r and r.ok) then return out end
	for path in r.stdout:gmatch("[^\n]+") do out[#out + 1] = load_record(path) end
	return out
end

-- --- Rex ----------------------------------------------------------------------

-- A script has to attach to a session before it can look inside it.
local attached = {}
local function attach(s)
	if attached[s] == nil then attached[s] = rex.call("session.attach", { session_id = s }) ~= nil end
	return attached[s]
end

local function block_method(s, b, method, args)
	if not attach(s) then return nil, "can't attach to " .. s end
	return rex.call("block.method", { session_id = s, block_id = b, method = method, args = args or {} })
end

local function foreground(s, b)
	local p = block_method(s, b, "process")
	return p and p.foreground
end

-- {block_id = {session, where}} for every pane Rex has right now.
local function live_panes()
	local live = {}
	local list = rex.call("session.list")
	for _, s in ipairs(list and list.sessions or {}) do
		local v = attach(s.session_id) and rex.call("session.view", { session_id = s.session_id })
		for _, w in ipairs(v and v.windows or {}) do
			for _, l in ipairs(w.layers or {}) do
				for _, b in ipairs(l.blocks or {}) do
					live[b.block_id] = {
						session = s.session_id,
						where = (s.label or s.session_id) .. " › " .. (w.label or "?") .. " › " .. (b.label or "pane"),
					}
				end
			end
		end
	end
	return live
end

local function send_resume(r, session, block)
	local cmd = resume_cmd[r.agent]
	if not cmd then return nil, "don't know how to resume " .. r.agent end
	return block_method(session, block, "write", { data = "cd " .. shq(r.cwd or "~") .. " && " .. cmd(r.session_id) .. "\r" })
end

-- --- recording (runs inside the agent's hooks) -------------------------------

-- True when the agent that ran this hook is the pane's foreground program.
-- A `claude -p` started from inside the pane inherits $REX_BLOCK too, and must
-- not overwrite the pane's record.
local function owns_pane(s, b, agent)
	local fg = foreground(s, b)
	if not (fg and fg.pid and self_pid) then return true end -- can't tell, so assume it does
	local ps = rex.exec({ "ps", "-A", "-o", "pid=,ppid=,args=" })
	if not (ps and ps.ok) then return true end
	local parent, name = {}, {}
	for line in ps.stdout:gmatch("[^\n]+") do
		local pid, ppid, a = line:match("^%s*(%d+)%s+(%d+)%s+(%S*)")
		if pid then parent[tonumber(pid)], name[tonumber(pid)] = tonumber(ppid), prog(a) end
	end
	local pid = self_pid
	for _ = 1, 12 do
		if not pid or pid <= 1 then return false end
		if pid == fg.pid then return true end
		if name[pid] == agent then return false end -- a nearer agent ran this hook
		pid = parent[pid]
	end
	return false
end

-- Claude Code hook payloads: hook_event_name, session_id, cwd, and reason on
-- SessionEnd. The shim ignores the exit status, so a hook never gets in the
-- agent's way.
local function hook(agent)
	local s, b = os.getenv("REX_SESSION") or "", os.getenv("REX_BLOCK") or ""
	if s == "" or b == "" then return end
	check_block(b)
	local ok, p = pcall(json.decode, io.read("*a") or "")
	if not (ok and type(p) == "table") then return end
	if p.hook_event_name == "SessionStart" then
		-- Every source (startup, resume, clear, compact) rewrites the record,
		-- since /clear and --resume can both change the ID.
		if (p.session_id or "") ~= "" and owns_pane(s, b, agent) then
			write_record({ agent = agent, session_id = p.session_id, cwd = p.cwd, rex_session = s, rex_block = b, updated_at = now() })
		end
	elseif p.hook_event_name == "SessionEnd" then
		-- Only a deliberate quit forgets. A reboot or a closed pane may still
		-- run SessionEnd, with reason "other", and then the record must stay.
		if p.reason == "prompt_input_exit" or p.reason == "logout" then
			local r = load_record(record_path(b))
			if r and r.agent == agent and r.session_id == p.session_id then os.remove(record_path(b)) end
		end
	end
end

-- --- restoring ---------------------------------------------------------------

-- Every record plus a status, newest first:
--   resume     the pane exists and sits at a shell prompt
--   running    the pane already runs that agent
--   busy       the pane runs something else
--   duplicate  a newer record has the same conversation
--   orphan     the pane is gone; /session-resume:recover deals with these
local function plan()
	local recs, live = records(), live_panes()
	-- Live panes before orphans, then newest first, so an orphan whose
	-- conversation is open elsewhere counts as a duplicate.
	table.sort(recs, function(a, b)
		local la, lb = live[a.rex_block] ~= nil, live[b.rex_block] ~= nil
		if la ~= lb then return la end
		if a.updated_at ~= b.updated_at then return (a.updated_at or "") > (b.updated_at or "") end
		return a.rex_block < b.rex_block
	end)
	local seen = {}
	for _, r in ipairs(recs) do
		local l = live[r.rex_block]
		local fg = l and not seen[r.session_id] and foreground(l.session, r.rex_block)
		local p = prog(fg and fg.argv0)
		if seen[r.session_id] then r.status = "duplicate"
		elseif not l then r.status = "orphan"
		elseif SHELLS[p] then r.status = "resume"
		elseif p == r.agent then r.status = "running"
		else r.status = "busy" end
		r.where, r.session, r.foreground = l and l.where, l and l.session, p ~= "" and p or nil
		if r.status == "resume" or r.status == "running" then seen[r.session_id] = true end
	end
	return recs
end

local function width(s) return #(s:gsub("[\128-\191]", "")) end

local function print_plan(p)
	local rows, w = {}, {}
	for _, r in ipairs(p) do
		local row = { r.status, r.where or ("(gone) " .. tostring(r.rex_session)), r.agent, r.session_id, r.cwd or "",
			r.status == "busy" and ("running " .. (r.foreground or "something")) or "" }
		rows[#rows + 1] = row
		for i, c in ipairs(row) do w[i] = math.max(w[i] or 0, width(c)) end
	end
	for _, row in ipairs(rows) do
		local line = ""
		for i, c in ipairs(row) do line = line .. c .. string.rep(" ", w[i] - width(c) + 2) end
		print((line:gsub("%s+$", "")))
	end
end

-- A duplicate's conversation is open in another pane now; its record is stale.
local function drop_duplicates(p)
	for _, r in ipairs(p) do
		if r.status == "duplicate" then os.remove(record_path(r.rex_block)) end
	end
end

local function count(p, status)
	local n = 0
	for _, r in ipairs(p) do if r.status == status then n = n + 1 end end
	return n
end

local function restore(yes)
	local p = plan()
	if #p == 0 then print("No recorded sessions.") return end
	print_plan(p)
	local n = count(p, "resume")
	if n > 0 then
		if not yes then
			io.write(('\nResume %d session(s) marked "resume"? [y/N] '):format(n))
			io.flush()
			local tty = io.open("/dev/tty", "r")
			local ans = tty and tty:read("*l") or ""
			if tty then tty:close() end
			if not (ans == "y" or ans == "Y" or ans == "yes") then print("Nothing resumed.") return end
		end
		for _, r in ipairs(p) do
			if r.status == "resume" then
				local ok, err = send_resume(r, r.session, r.rex_block)
				print(ok and ("resumed " .. r.agent .. " " .. r.session_id) or ("couldn't resume " .. r.session_id .. ": " .. tostring(err)))
			end
		end
	end
	drop_duplicates(p)
	local o = count(p, "orphan")
	if o > 0 then
		print(("\n%d session(s) lost their pane. Run /session-resume:recover in Claude Code to sort them out."):format(o))
	end
end

-- --- autostart (launched detached from init.lua) ------------------------------

-- init.lua runs when the server starts and again on every `rex config reload`,
-- and can't make session calls itself. So it launches this in the background:
-- wait for the server to finish restoring, then resume without asking. The
-- server's instance_id changes on each start, which tells a start from a reload.
local function autostart()
	rex.exec({ "mkdir", "-p", state_root })
	local logf = io.open(state_root .. "/autostart.log", "a")
	local function log(msg)
		if logf then logf:write(now(), " ", msg, "\n"); logf:flush() end
	end

	local st = rex.call("server.status")
	local inst = st and st.instance_id
	if not inst then log("server status has no instance_id") return end
	-- mkdir is atomic, so two reloads in a row can't both get past here.
	local m = rex.exec({ "mkdir", state_root .. "/.autostart-" .. inst })
	if not (m and m.ok) then return end
	rex.exec({ "find", state_root, "-maxdepth", "1", "-name", ".autostart-*", "!", "-name", ".autostart-" .. inst,
		"-exec", "rmdir", "{}", ";" })
	log("server " .. inst .. " started")

	-- Rex restores its sessions after loading the config. Wait until the
	-- session count stops changing.
	local prev, same = -1, 0
	for _ = 1, 60 do
		local l = rex.call("session.list")
		local n = l and l.sessions and #l.sessions or -1
		if n == prev and n >= 0 then same = same + 1 else same, prev = 0, n end
		if same >= 3 then break end
		rex.sleep(1)
	end

	-- Shells come up a moment after their panes, so a pane with no foreground
	-- program yet is checked again. Each pane is resumed at most once.
	local done, p = {}, {}
	for _ = 1, 30 do
		p = plan()
		local waiting = 0
		for _, r in ipairs(p) do
			if r.status == "resume" and not done[r.rex_block] then
				done[r.rex_block] = true
				local ok, err = send_resume(r, r.session, r.rex_block)
				log(ok and ("resumed " .. r.agent .. " " .. r.session_id .. " in " .. r.rex_block)
					or ("couldn't resume " .. r.session_id .. ": " .. tostring(err)))
			elseif r.status == "busy" and not r.foreground then
				waiting = waiting + 1
			end
		end
		if waiting == 0 then break end
		rex.sleep(1)
	end

	drop_duplicates(p)
	for _, r in ipairs(p) do
		if not done[r.rex_block] then
			log(("%s %s %s %s %s"):format(r.status == "duplicate" and "dropped" or "left", r.status,
				r.agent, r.session_id, r.where or r.rex_session))
		end
	end
	log("done")
end

-- --- setup (installs into Claude Code and Rex) --------------------------------

-- Like `rex skill setup`: the installed files only point back at this command,
-- so updating session-resume updates what they do. Run setup again only if
-- the command moves.
local VERSION = "0.2.0"
local HOME = os.getenv("HOME")
local shim = arg("shim")
local lib_dir = shim:gsub("/bin/[^/]*$", "") .. "/lib"

-- Claude Code loads any plugin folder under ~/.claude/skills as
-- session-resume@skills-dir: no marketplace and no settings.json entry.
local plugin_dir = (os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")) .. "/skills/session-resume"
-- Rex has no drop-in folder, so setup owns one marked block of init.lua.
local init_lua = os.getenv("REX_CONFIG") or ((os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/rex/init.lua")
local BEGIN, END = "-- >>> session-resume (managed by `session-resume setup`)", "-- <<< session-resume"

local function q(s) return json.encode(s) end -- a JSON string is also a Lua string

local function plugin_files()
	local cmd = shq(shim)
	local hook = ('{ "hooks": [ { "type": "command", "command": %s, "timeout": 10 } ] }'):format(q(cmd .. " hook claude"))
	return {
		[".claude-plugin/plugin.json"] = ([[
{
  "name": "session-resume",
  "version": %s,
  "description": "Reopen Claude Code conversations in their Rex panes after a Rex restart or a reboot",
  "repository": "https://github.com/qstearns/session-resume"
}
]]):format(q(VERSION)),
		["hooks/hooks.json"] = ([[
{
  "hooks": {
    "SessionStart": [ %s ],
    "SessionEnd": [ %s ]
  }
}
]]):format(hook, hook),
		["skills/recover/SKILL.md"] = ([[
---
name: recover
description: Find agent conversations that session-resume recorded but could not put back, because the Rex pane they were in no longer exists, and ask the user what to do with each one. Use when `session-resume restore` reports sessions that lost their pane, or the user asks to recover lost Claude sessions after a Rex restart or reboot.
---

Run `%s skill recover` and follow the instructions it prints.
]]):format(cmd),
	}
end

-- Rex starts at login with a bare PATH, so the block gives it rex's own
-- directory plus the system one.
local function init_block()
	local rexdir
	for d in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local f = io.open(d .. "/rex", "r")
		if f then f:close(); rexdir = d; break end
	end
	if not rexdir then die("can't find rex on PATH") end
	return table.concat({
		BEGIN,
		"-- Reopen agent conversations in their panes when the Rex server starts.",
		("rex.exec.start({ %s, \"autostart\" }, { detach = true, env = { PATH = %s } })"):format(q(shim), q(rexdir .. ":/usr/bin:/bin")),
		END,
	}, "\n")
end

-- init.lua split around our block: text before, the block (or nil), text after.
local function split_init()
	local s = read_file(init_lua) or ""
	local a = s:find(BEGIN, 1, true)
	local b = a and s:find(END, a, true)
	if not b then return s, nil, "" end
	local e = b + #END
	if s:sub(e, e) == "\n" then e = e + 1 end
	return s:sub(1, a - 1), s:sub(a, b + #END - 1), s:sub(e)
end

local function write_file(path, s)
	rex.exec({ "mkdir", "-p", (path:gsub("/[^/]*$", "")) })
	local f = assert(io.open(path, "w"))
	f:write(s)
	f:close()
end

local function home(p) return (p:gsub("^" .. HOME:gsub("%p", "%%%0"), "~")) end

-- A marketplace plugin with the same name would win over the skills-dir one.
local function marketplace_copy()
	local s = read_file((os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")) .. "/plugins/installed_plugins.json") or ""
	return s:match('"(session%-resume@[^"]+)"')
end

local function status()
	local fresh, files = true, plugin_files()
	local names = {}
	for name in pairs(files) do names[#names + 1] = name end
	table.sort(names)
	print("Claude Code  " .. home(plugin_dir))
	for _, name in ipairs(names) do
		local have = read_file(plugin_dir .. "/" .. name)
		local st = have == files[name] and "ok" or have and "outdated" or "missing"
		fresh = fresh and st == "ok"
		print(("  %-9s %s"):format(st, name))
	end
	local mp = marketplace_copy()
	if mp then
		fresh = false
		print("  conflict  " .. mp .. " is installed and hides this one; run: claude plugin uninstall " .. mp)
	end
	local _, block = split_init()
	local st = block == init_block() and "ok" or block and "outdated" or "missing"
	fresh = fresh and st == "ok"
	print("\nRex  " .. home(init_lua))
	print(("  %-9s autostart block"):format(st))
	if not fresh then print('\nRun "session-resume setup" to install or update.') end
end

local function setup()
	for name, s in pairs(plugin_files()) do write_file(plugin_dir .. "/" .. name, s) end
	print("Claude Code: wrote " .. home(plugin_dir) .. " (loads as session-resume@skills-dir)")
	local before, block, after = split_init()
	local want = init_block()
	if block ~= want then
		if block then
			write_file(init_lua, before .. want .. "\n" .. after)
		else
			write_file(init_lua, before .. ((before == "" or before:sub(-2) == "\n\n") and "" or before:sub(-1) == "\n" and "\n" or "\n\n") .. want .. "\n")
		end
	end
	print("Rex: " .. (block == want and "already set up in " or "updated ") .. home(init_lua))
	local mp = marketplace_copy()
	if mp then print("\nAlso installed from a marketplace, which hides this copy. Remove it with:\n  claude plugin uninstall " .. mp) end
	print("\nRestart running Claude Code sessions to load the hooks.")
end

local function remove()
	if read_file(plugin_dir .. "/.claude-plugin/plugin.json") then
		rex.exec({ "rm", "-rf", plugin_dir })
		print("Claude Code: removed " .. home(plugin_dir))
	end
	local before, block, after = split_init()
	if block then
		write_file(init_lua, before .. after)
		print("Rex: removed the autostart block from " .. home(init_lua))
	end
	print("Records in " .. home(state_root) .. " are left alone.")
end

local function show_skill(name)
	if not (name or ""):match("^[%w%-]+$") then die("usage: skill recover") end
	local s = read_file(lib_dir .. "/" .. name .. ".md")
	if not s then die("no skill named " .. name) end
	io.write(s)
end

-- Resume one record, in its own pane or in another one (the new pane's agent
-- then records itself there, so the old record is dropped).
local function resume_one(b, to)
	check_block(b)
	local r = load_record(record_path(b))
	if not r then die("no record for " .. b) end
	to = to or b
	check_block(to)
	local l = live_panes()[to]
	if not l then die("no live pane " .. to) end
	local fg = foreground(l.session, to)
	local p = prog(fg and fg.argv0)
	if not SHELLS[p] then die(("pane %s is running %s, not a shell"):format(to, p ~= "" and p or "something")) end
	local ok, err = send_resume(r, l.session, to)
	if not ok then die("couldn't type into " .. to .. ": " .. tostring(err)) end
	if to ~= b then os.remove(record_path(b)) end
	print(("resumed %s %s in %s"):format(r.agent, r.session_id, to))
end

-- --- main ---------------------------------------------------------------------

local cmd = table.remove(argv, 1)
if cmd == "hook" then
	if #argv ~= 1 then die("usage: hook AGENT") end
	hook(argv[1])
elseif cmd == "list" then
	local p = plan()
	if argv[1] == "--json" then print(#p == 0 and "[]" or json.encode(p)) else print_plan(p) end
elseif cmd == "restore" then
	restore(argv[1] == "-y")
elseif cmd == "autostart" then
	autostart()
elseif cmd == "setup" then
	setup()
elseif cmd == "status" then
	status()
elseif cmd == "remove" then
	remove()
elseif cmd == "skill" then
	show_skill(argv[1])
elseif cmd == "resume" then
	if #argv < 1 or #argv > 2 then die("usage: resume BLOCK [TARGET_BLOCK]") end
	resume_one(argv[1], argv[2])
elseif cmd == "drop" then
	if #argv < 1 then die("usage: drop BLOCK...") end
	for _, b in ipairs(argv) do check_block(b); os.remove(record_path(b)) end
else
	die("usage: session-resume setup|status|remove|list|restore|resume|drop|skill|hook|autostart ...")
end
