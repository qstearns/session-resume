-- Codex: SessionStart/SessionEnd hooks in hooks.json, copied to
-- ~/.codex/hooks.json and trusted once with /hooks.
return {
  name = "codex",
  resume = function(state)
    return { "codex", "resume", state.session_id }
  end,
}
