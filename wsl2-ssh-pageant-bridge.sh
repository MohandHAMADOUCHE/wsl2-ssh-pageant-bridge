#!/bin/bash

# --- CONFIGURATION ---
export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"
NPIPERELAY_PATH="$HOME/.local/bin/npiperelay.exe"
SOCAT_LOG="${TMPDIR:-/tmp}/wsl2-ssh-pageant-bridge-socat.log"
NPIPERELAY_CACHE_DIR="$HOME/.cache/wsl2-ssh-pageant-bridge"

# Verbose mode detection
VERBOSE=false
[[ "$1" == "-v" ]] && VERBOSE=true

# 1. Cleanup
killall socat npiperelay.exe 2>/dev/null
rm -f "$SSH_AUTH_SOCK"
mkdir -p "$(dirname "$SSH_AUTH_SOCK")"

# 2. Pageant pipe detection
PIPE_NAME=$(powershell.exe -Command "(Get-ChildItem \\\\.\\pipe\\ | Where-Object { \$_.Name -like '*pageant*' } | Select-Object -First 1).Name" 2>/dev/null | tr -d '\r')

# Error: Pageant not found (always shown)
if [ -z "$PIPE_NAME" ]; then
    echo "❌ Error: Pageant (Windows) was not detected. Make sure it is running."
    return 1 2>/dev/null || exit 1
fi

CLEAN_PIPE="//./pipe/$PIPE_NAME"

# Error: Missing binary (always shown)
if [ ! -f "$NPIPERELAY_PATH" ]; then
    ALT_NPIPERELAY_PATH=$(command -v npiperelay.exe 2>/dev/null || command -v npiperelay 2>/dev/null)
    if [ -n "$ALT_NPIPERELAY_PATH" ] && [ -f "$ALT_NPIPERELAY_PATH" ]; then
        NPIPERELAY_PATH="$ALT_NPIPERELAY_PATH"
    else
        echo "❌ Error: npiperelay.exe not found at $NPIPERELAY_PATH"
        return 1 2>/dev/null || exit 1
    fi
fi

# Make npiperelay executable (or use a user-local copy if root-owned)
if [ ! -x "$NPIPERELAY_PATH" ]; then
    if [ -w "$NPIPERELAY_PATH" ]; then
        chmod +x "$NPIPERELAY_PATH" 2>/dev/null || true
    fi

    if [ ! -x "$NPIPERELAY_PATH" ]; then
        mkdir -p "$NPIPERELAY_CACHE_DIR"
        USER_NPIPERELAY_PATH="$NPIPERELAY_CACHE_DIR/npiperelay.exe"
        cp "$NPIPERELAY_PATH" "$USER_NPIPERELAY_PATH" 2>/dev/null || {
            echo "❌ Error: npiperelay.exe is not executable and local copy failed."
            echo "👉 Action: Run 'sudo chmod +x $NPIPERELAY_PATH' then retry."
            return 1 2>/dev/null || exit 1
        }
        chmod +x "$USER_NPIPERELAY_PATH" 2>/dev/null || {
            echo "❌ Error: Unable to make $USER_NPIPERELAY_PATH executable"
            return 1 2>/dev/null || exit 1
        }
        NPIPERELAY_PATH="$USER_NPIPERELAY_PATH"
    fi
fi

# 3. Start bridge
rm -f "$SOCAT_LOG"
nohup socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork EXEC:"$NPIPERELAY_PATH -ei -s $CLEAN_PIPE",nofork >"$SOCAT_LOG" 2>&1 &

# Short wait for socket creation (avoid startup false negatives)
for _ in {1..30}; do
    [ -S "$SSH_AUTH_SOCK" ] && break
    sleep 0.1
done

if [ ! -S "$SSH_AUTH_SOCK" ]; then
    echo "❌ Error: SSH socket was not created ($SSH_AUTH_SOCK)."
    [ -s "$SOCAT_LOG" ] && echo "Detail: $(tail -n 1 "$SOCAT_LOG")"
    return 1 2>/dev/null || exit 1
fi

# 4. Check key state
CHECK_KEYS=$(ssh-add -l 2>&1)
CHECK_STATUS=$?

if [ "$CHECK_STATUS" -eq 0 ]; then
    # Success: show only when -v is used
    if [ "$VERBOSE" = true ]; then
        echo "✅ Bridge enabled on: $CLEAN_PIPE"
        echo "🔑 Keys detected:"
        echo "$CHECK_KEYS"
    fi
elif [ "$CHECK_STATUS" -eq 1 ]; then
    # Empty agent: always show warning
    echo "⚠️  Warning: Agent is empty. Bridge is running but no key was detected."
    echo "👉 Action: In Windows, right-click Pageant -> 'Add CAPI cert'."
else
    # Communication error: status 2 (or other unexpected code)
    echo "❌ Error: Communication issue with the SSH agent."
    [ "$VERBOSE" = true ] && echo "Detail: $CHECK_KEYS"
fi
