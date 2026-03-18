#!/usr/bin/env bash

set -euo pipefail

COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'

info() { echo -e "${COLOR_BLUE}ℹ️  $1${COLOR_RESET}"; }
success() { echo -e "${COLOR_GREEN}✅ $1${COLOR_RESET}"; }
warn() { echo -e "${COLOR_YELLOW}⚠️  $1${COLOR_RESET}"; }
error() { echo -e "${COLOR_RED}❌ $1${COLOR_RESET}" >&2; exit 1; }

WRAPPER_PATH="$HOME/tmux-ssh-agent-wrapper.sh"
BASH_ENV_DIR="$HOME/.bash"
BASH_ENV_PATH="$BASH_ENV_DIR/tmux-bash-env.bash"
TMUX_CONF_PATH="$HOME/.tmux.conf"
BASHRC_PATH="$HOME/.bashrc"

TMUX_BLOCK_START="# BEGIN WSL2 SSH PAGEANT BRIDGE TMUX"
TMUX_BLOCK_END="# END WSL2 SSH PAGEANT BRIDGE TMUX"
BASHRC_BLOCK_START="# BEGIN WSL2 SSH PAGEANT BRIDGE BASHRC"
BASHRC_BLOCK_END="# END WSL2 SSH PAGEANT BRIDGE BASHRC"

## Create target file if it does not exist yet.
ensure_file() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    touch "$file_path"
  fi
}

## Remove a managed block delimited by start/end markers.
remove_managed_block() {
  local file_path="$1"
  local start_marker="$2"
  local end_marker="$3"

  # Remove previously managed block to keep script idempotent.
  if grep -qF "$start_marker" "$file_path" 2>/dev/null; then
    sed -i "/$start_marker/,/$end_marker/d" "$file_path"
  fi
}

## Generate/update the tmux SSH wrapper script used for resilient SSH calls.
install_wrapper() {
  info "Installing wrapper to $WRAPPER_PATH"

  cat > "$WRAPPER_PATH" << 'EOF'
#!/usr/bin/env bash

REAL_SSH="${REAL_SSH:-/usr/bin/ssh}"

## Compute a per-pane incremental delay to avoid simultaneous SSH bursts.
get_auto_delay() {
  local state_root="${TMPDIR:-/tmp}/tmux-ssh-agent-wrapper"
  local session_id=""
  local session_key lock_dir counter_file counter=0

  mkdir -p "$state_root"
  if [ -n "$TMUX_PANE" ]; then
    session_id="$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null)"
  fi
  session_key="${session_id:-default}"
  lock_dir="$state_root/${session_key}.lock"
  counter_file="$state_root/${session_key}.counter"

  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
  done

  [ -f "$counter_file" ] && counter="$(<"$counter_file")"
  printf '%s\n' "$((counter + 1))" > "$counter_file"
  rmdir "$lock_dir"

  awk -v counter="$counter" 'BEGIN { printf "%.1f\n", counter * 0.4 }'
}

export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/wsl-ssh-agent.sock}"
SSH_OPTS=(
  # Force ssh to use the WSL Pageant bridge socket.
  -o "IdentityAgent=$SSH_AUTH_SOCK"
  # Do not try private key files from disk in this workflow.
  -o "IdentityFile=none"
  # Force public-key auth to stay enabled even if another SSH config overrides it.
  -o "PubkeyAuthentication=unbound"
  # Prefer public-key auth first (Pageant-managed identities).
  -o "PreferredAuthentications=publickey"
  # Non-interactive mode: fail fast instead of waiting for prompts.
  -o "BatchMode=yes"
  # Fast network timeout to avoid hanging panes.
  -o "ConnectTimeout=10"
  # Keepalive ping cadence for long-lived tmux sessions.
  -o "ServerAliveInterval=15"
  # Stop after missed keepalives (detect dead sessions quickly).
  -o "ServerAliveCountMax=2"
)

## Run ssh with retries and optional verbose debug on persistent failures.
run_with_retry() {
  local target="$1"
  shift
  local rc=255 attempt

  for attempt in 1 2 3 4 5; do
    "$REAL_SSH" "${SSH_OPTS[@]}" "$@"
    rc=$?
    [ "$rc" -eq 0 ] && break

    if [ "$rc" -eq 255 ] && [ "$attempt" -lt 5 ]; then
      printf '\nSSH_RETRY:%s attempt %s/5\n' "$target" "$attempt"
      sleep 3
      continue
    fi

    printf '\nSSH_DEBUG:%s\n' "$target"
    "$REAL_SSH" -vv "${SSH_OPTS[@]}" "$@"
    break
  done

  printf '\nSSH_EXIT:%s\n' "$rc"
  return "$rc"
}

## Detect interactive tmux ssh calls where pane should stay open after command.
should_keep_shell_open() {
  # When tmux runs commands like: split-window 'ssh -t host',
  # the pane exits right after ssh unless we reopen a shell.
  # We only keep it open for interactive ssh invocations (-t/-tt).
  [ -n "${TMUX_PANE:-}" ] || return 1
  local arg
  for arg in "$@"; do
    case "$arg" in
      -t|-tt) return 0 ;;
    esac
  done
  return 1
}

if [ "$#" -eq 1 ]; then
  HOST="$1"
  DELAY="$(get_auto_delay)"
  sleep "${DELAY:-0}"
  run_with_retry "$HOST" -t "$HOST"
  exec bash
elif [ "$#" -eq 2 ] && [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  DELAY="$1"
  HOST="$2"
  sleep "${DELAY:-0}"
  run_with_retry "$HOST" -t "$HOST"
  exec bash
else
  DELAY="$(get_auto_delay)"
  sleep "${DELAY:-0}"
  TARGET="${!#}"
  run_with_retry "$TARGET" "$@"
  rc=$?
  if should_keep_shell_open "$@"; then
    exec bash
  fi
  exit "$rc"
fi
EOF

  chmod +x "$WRAPPER_PATH"
  success "Wrapper installed"
}

## Generate/update the BASH_ENV file used by tmux non-interactive bash shells.
install_bash_env() {
  info "Installing tmux BASH_ENV script to $BASH_ENV_PATH"
  mkdir -p "$BASH_ENV_DIR"

  # BASH_ENV is sourced by non-interactive bash shells started by tmux
  # (new-window/split-window with command). This guarantees wrapper usage
  # even when ~/.bashrc is not loaded.
  cat > "$BASH_ENV_PATH" << 'EOF'
#!/usr/bin/env bash

export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/wsl-ssh-agent.sock}"

ssh() {
  "$HOME"/tmux-ssh-agent-wrapper.sh "$@"
}

export -f ssh
EOF

  chmod +x "$BASH_ENV_PATH"
  success "BASH_ENV script installed"
}

## Inject/update managed tmux configuration block for env + keybindings.
configure_tmux_conf() {
  info "Configuring $TMUX_CONF_PATH"
  ensure_file "$TMUX_CONF_PATH"

  remove_managed_block "$TMUX_CONF_PATH" "$TMUX_BLOCK_START" "$TMUX_BLOCK_END"

  cat >> "$TMUX_CONF_PATH" << 'EOF'

# BEGIN WSL2 SSH PAGEANT BRIDGE TMUX
# Ensure tmux uses bash for command execution and inject wrapper in non-interactive shells
set -g default-shell /bin/bash
set-environment -gF SSH_AUTH_SOCK "#{HOME}/.ssh/wsl-ssh-agent.sock"
set-environment -gF BASH_ENV "#{HOME}/.bash/tmux-bash-env.bash"

# Keep terminal native selection/paste behavior by default
set -g mouse off

# Toggle mouse mode on/off
bind -n C-g if -F '#{mouse}' 'set -g mouse off; display-message "Mouse: OFF"' 'set -g mouse on; display-message "Mouse: ON"'

# Kill current session / all tmux sessions
bind -n C-x confirm-before -p "Kill session #S? (y/n)" kill-session
bind -n C-k confirm-before -p "Kill tmux server (all sessions)? (y/n)" kill-server
# END WSL2 SSH PAGEANT BRIDGE TMUX
EOF

  success "tmux config updated"
}

## Inject/update managed bashrc block so interactive tmux shells use wrapper too.
configure_bashrc() {
  info "Configuring $BASHRC_PATH"
  ensure_file "$BASHRC_PATH"

  remove_managed_block "$BASHRC_PATH" "$BASHRC_BLOCK_START" "$BASHRC_BLOCK_END"

  cat >> "$BASHRC_PATH" << 'EOF'

# BEGIN WSL2 SSH PAGEANT BRIDGE BASHRC
# In tmux interactive shells, load centralized ssh wrapper function
if [ -n "$TMUX" ] && [ -f "$HOME/.bash/tmux-bash-env.bash" ]; then
  . "$HOME/.bash/tmux-bash-env.bash"
fi
# END WSL2 SSH PAGEANT BRIDGE BASHRC
EOF

  success "bashrc updated"
}

## Reload tmux server config when a tmux server is already running.
reload_tmux_if_running() {
  if ! command -v tmux >/dev/null 2>&1; then
    warn "tmux not found, skipping reload"
    return
  fi

  if tmux ls >/dev/null 2>&1; then
    info "Reloading tmux configuration"
    tmux source-file "$TMUX_CONF_PATH" || warn "Could not reload tmux automatically"
    success "tmux config reloaded"
  else
    info "No running tmux server detected"
  fi
}

## Orchestrate full setup: wrapper, BASH_ENV, tmux config, bashrc, reload.
main() {
  info "Applying tmux SSH bridge setup"
  install_wrapper
  install_bash_env
  configure_tmux_conf
  configure_bashrc
  reload_tmux_if_running

  success "Done"
  info "Next steps:"
  echo " Open a new terminal (or run: source ~/.bashrc)"
}

main "$@"
