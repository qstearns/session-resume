-- OpenCode: session-resume.js, copied to ~/.config/opencode/plugins/.
return {
  name = "opencode",
  resume = function(state)
    return { "opencode", "--session", state.session_id }
  end,
}
