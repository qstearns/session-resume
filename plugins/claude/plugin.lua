-- Claude Code: SessionStart/SessionEnd hooks in hooks.json, merged into
-- ~/.claude/settings.json.
return {
  name = "claude",
  resume = function(state)
    return { "claude", "--resume", state.session_id }
  end,
}
