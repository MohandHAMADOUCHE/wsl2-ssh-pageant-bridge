#!/bin/bash

# WSL2 SSH Pageant Bridge Uninstaller
# This script cleanly removes all components of WSL2 SSH Pageant Bridge.

# --- Colors for output ---
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'

info() {
    echo -e "${COLOR_BLUE}ℹ️  $1${COLOR_RESET}"
}

success() {
    echo -e "${COLOR_GREEN}✅ $1${COLOR_RESET}"
}

warn() {
    echo -e "${COLOR_YELLOW}⚠️  $1${COLOR_RESET}"
}

# --- Configuration ---
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
NPIPERELAY_PATH="$BIN_DIR/npiperelay.exe"
BRIDGE_SCRIPT_PATH="$BIN_DIR/wsl2-ssh-pageant-bridge.sh"
SERVICE_FILE_PATH="$SYSTEMD_DIR/wsl2-ssh-pageant-bridge.service"
LEGACY_BRIDGE_SCRIPT_PATH="$BIN_DIR/pki-bridge.sh"
LEGACY_SERVICE_FILE_PATH="$SYSTEMD_DIR/pki-bridge.service"
EXPORT_LINE='export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"'
SHELL_COMMENT='# Added by wsl2-ssh-pageant-bridge installer'
LEGACY_SHELL_COMMENT='# Added by wsl-pki-bridge installer'

# --- Main Logic ---
main() {
    info "Starting WSL2 SSH Pageant Bridge uninstallation..."

    stop_systemd
    remove_files
    unconfigure_shell

    success "Uninstallation complete!"
    warn "Please open a new terminal or run 'source ~/.bashrc' (or ~/.zshrc) to apply the changes."
}

stop_systemd() {
    info "Stopping and disabling systemd service..."
    systemctl --user stop wsl2-ssh-pageant-bridge.service >/dev/null 2>&1 || true
    systemctl --user disable wsl2-ssh-pageant-bridge.service >/dev/null 2>&1 || true
    systemctl --user stop pki-bridge.service >/dev/null 2>&1 || true
    systemctl --user disable pki-bridge.service >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    success "Systemd service stopped and disabled."
}

remove_files() {
    info "Removing service and script files..."
    rm -f "$SERVICE_FILE_PATH" "$BRIDGE_SCRIPT_PATH" "$LEGACY_SERVICE_FILE_PATH" "$LEGACY_BRIDGE_SCRIPT_PATH" "$NPIPERELAY_PATH"
    success "Files removed."
}

unconfigure_shell() {
    info "Removing shell configuration..."
    local shell_config_files=()

    [ -f "$HOME/.bashrc" ] && shell_config_files+=("$HOME/.bashrc")
    [ -f "$HOME/.zshrc" ] && shell_config_files+=("$HOME/.zshrc")

    if [ ${#shell_config_files[@]} -eq 0 ]; then
        warn "Could not detect .bashrc or .zshrc. You may need to remove the SSH_AUTH_SOCK export manually."
        return
    fi

    local cleaned_any=false
    for shell_config_file in "${shell_config_files[@]}"; do
        if grep -qF "$EXPORT_LINE" "$shell_config_file"; then
            sed -i -e "\|$SHELL_COMMENT|d" -e "\|$LEGACY_SHELL_COMMENT|d" -e "\|$EXPORT_LINE|d" "$shell_config_file"
            success "Shell configuration removed from $shell_config_file."
            cleaned_any=true
        else
            info "Shell configuration not found in $shell_config_file. Skipping."
        fi
    done

    if [ "$cleaned_any" = false ]; then
        info "No wsl2-ssh-pageant-bridge shell export found."
    fi
}

# --- Run Script ---
main