#!/bin/sh
# Forward one Claude Code hook event to the ClaudePet app.

STATE_DIRECTORY="$HOME/.claude-pet"
PROCESS_FILE="$STATE_DIRECTORY/app.pid"
EVENTS_FILE="$STATE_DIRECTORY/events.jsonl"

# Skip when the pet is not running
[ -f "$PROCESS_FILE" ] || exit 0
read -r PET_PROCESS < "$PROCESS_FILE"
[ -n "$PET_PROCESS" ] || exit 0
kill -0 "$PET_PROCESS" 2>/dev/null || exit 0

# Find jq
JQ_PROGRAM="/usr/bin/jq"
[ -x "$JQ_PROGRAM" ] || JQ_PROGRAM="$(command -v jq)"
[ -n "$JQ_PROGRAM" ] || exit 0

# Append the fields the pet needs as one line
"$JQ_PROGRAM" -c '{
    time: now,
    session: .session_id,
    event: .hook_event_name,
    tool: .tool_name,
    notification: .notification_type,
    source: .source,
    interrupt: .is_interrupt,
    title: .session_title,
    directory: .cwd,
    host: env.CLAUDE_CODE_HOST_SESSION_ID,
    transcript: .transcript_path
}' >> "$EVENTS_FILE" 2>/dev/null

exit 0
