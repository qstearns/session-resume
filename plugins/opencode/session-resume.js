// Records the open OpenCode session for the Rex block it runs in.
//
// OpenCode has no session-start event that fires on `--session` resume, and
// no exit event, so record on creation and again whenever the session goes
// idle (after each turn). Nothing is ever forgotten from here.
export const SessionResume = async ({ $, directory }) => {
  if (!process.env.REX_BLOCK) return {}

  let recorded
  const record = async (sessionID) => {
    if (!sessionID || sessionID === recorded) return
    recorded = sessionID
    await $`session-resume record opencode ${sessionID} ${directory}`.quiet().nothrow()
  }

  return {
    event: async ({ event }) => {
      const props = event.properties ?? {}
      if (event.type === "session.created") {
        // Subagent sessions have a parent; keep the top-level one.
        if (!props.info?.parentID) await record(props.info?.id)
      } else if (event.type === "session.idle") {
        await record(props.sessionID)
      }
    },
  }
}
