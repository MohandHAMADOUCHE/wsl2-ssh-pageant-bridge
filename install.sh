#!/bin/bash

# WSL2 SSH Pageant Bridge Installer
# This script automates the installation of WSL2 SSH Pageant Bridge.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Colors for output ---
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
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

error() {
    echo -e "${COLOR_RED}❌ $1${COLOR_RESET}" >&2
    exit 1
}

# --- Configuration ---
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
NPIPERELAY_PATH="$BIN_DIR/npiperelay.exe"
BRIDGE_SCRIPT_NAME="wsl2-ssh-pageant-bridge.sh"
SERVICE_NAME="wsl2-ssh-pageant-bridge.service"
BRIDGE_SCRIPT_PATH="$BIN_DIR/$BRIDGE_SCRIPT_NAME"
SERVICE_FILE_PATH="$SYSTEMD_DIR/$SERVICE_NAME"
LEGACY_BRIDGE_SCRIPT_PATH="$BIN_DIR/pki-bridge.sh"
LEGACY_SERVICE_FILE_PATH="$SYSTEMD_DIR/pki-bridge.service"
EXPORT_LINE='export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"'
SHELL_COMMENT='# Added by wsl2-ssh-pageant-bridge installer'
LEGACY_SHELL_COMMENT='# Added by wsl-pki-bridge installer'
NPIPERELAY_RELEASE_URL="https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip"
NPIPERELAY_API_LATEST_URL="https://api.github.com/repos/jstarks/npiperelay/releases/latest"

print_banner() {
    echo -e "${COLOR_BLUE}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║              WSL2 SSH PAGEANT BRIDGE                 ║
║                      Installer                       ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${COLOR_RESET}"
}

# --- Main Logic ---
main() {
    print_banner
    info "Starting WSL2 SSH Pageant Bridge installation..."

    # Check if running from the repository directory
    if [ ! -f "$BRIDGE_SCRIPT_NAME" ] || [ ! -f "$SERVICE_NAME" ]; then
        error "Please run this script from the root of the 'wsl2-ssh-pageant-bridge' repository directory."
    fi

    check_dependencies
    install_npiperelay
    setup_scripts
    check_pageant_preflight
    setup_systemd
    configure_shell

    success "Installation complete!"
    warn "Please open a new terminal or run 'source ~/.bashrc' (or ~/.zshrc) to apply the changes."
    info "You can verify the installation by running 'ssh-add -l' in the new terminal."
}

check_pageant_preflight() {
    info "Checking Pageant availability (preflight)..."

    local pageant_pipe
    pageant_pipe=$(powershell.exe -Command "(Get-ChildItem \\\\.\\pipe\\ | Where-Object { \$_.Name -like '*pageant*' } | Select-Object -First 1).Name" 2>/dev/null | tr -d '\r')

    if [ -z "$pageant_pipe" ]; then
        warn "Pageant is not detected on Windows."
        warn "Action: Start Pageant and load your cert/key (Add CAPI cert)."
        warn "Then run: systemctl --user restart $SERVICE_NAME"
    else
        info "Pageant pipe detected: $pageant_pipe"
    fi
}

check_dependencies() {
    info "Checking for required packages..."
    local missing_packages=()
    for pkg in socat curl unzip; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        warn "The following packages are missing: ${missing_packages[*]}"
        if command -v apt-get &> /dev/null; then
            info "Attempting to install them with apt..."
            sudo apt-get update
            sudo apt-get install -y "${missing_packages[@]}"
        elif command -v dnf &> /dev/null; then
            info "Attempting to install them with dnf..."
            sudo dnf install -y "${missing_packages[@]}"
        elif command -v pacman &> /dev/null; then
            info "Attempting to install them with pacman..."
            sudo pacman -Sy --noconfirm "${missing_packages[@]}"
        elif command -v zypper &> /dev/null; then
            info "Attempting to install them with zypper..."
            sudo zypper --non-interactive install "${missing_packages[@]}"
        else
            error "No supported package manager found (apt, dnf, pacman, zypper). Please install: ${missing_packages[*]}"
        fi
    fi
    success "All dependencies are satisfied."
}

build_systemd_path_line() {
    local win_sys32="/mnt/c/Windows/System32"
    local base_path="%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    if command -v wslpath &> /dev/null; then
        local detected_sys32
        detected_sys32=$(wslpath -u 'C:\\Windows\\System32' 2>/dev/null || true)
        if [ -n "$detected_sys32" ] && [ -d "$detected_sys32" ]; then
            win_sys32="$detected_sys32"
        fi
    fi

    local win_powershell="$win_sys32/WindowsPowerShell/v1.0"
    echo "Environment=PATH=$base_path:$win_sys32:$win_powershell"
}

install_npiperelay() {
    info "Setting up npiperelay..."
    mkdir -p "$BIN_DIR"

    if [ -f "$NPIPERELAY_PATH" ]; then
        info "npiperelay.exe already found at destination. Skipping setup."
        return
    fi

    # If present locally, copy it instead of downloading.
    if [ -f "./npiperelay.exe" ]; then
        info "Found local npiperelay.exe. Copying to $BIN_DIR..."
        cp "./npiperelay.exe" "$NPIPERELAY_PATH"
        chmod +x "$NPIPERELAY_PATH"
        success "npiperelay.exe installed to $NPIPERELAY_PATH"
        return
    fi

    info "Downloading npiperelay release..."
    local download_url="$NPIPERELAY_RELEASE_URL"

    if ! curl -fsSL -o "/tmp/npiperelay.zip" "$download_url"; then
        warn "Direct npiperelay download failed, trying GitHub API latest release..."
        download_url=$(curl -s "$NPIPERELAY_API_LATEST_URL" | grep "browser_download_url.*\.zip" | sed -e 's/.*"browser_download_url": "//' -e 's/".*//')

        if [ -z "$download_url" ]; then
            error "Could not find npiperelay download URL. Please download it manually into this directory and re-run."
        fi

        curl -L -o "/tmp/npiperelay.zip" "$download_url"
    fi

    unzip -o "/tmp/npiperelay.zip" "npiperelay.exe" -d "$BIN_DIR"
    chmod +x "$NPIPERELAY_PATH"
    rm "/tmp/npiperelay.zip"

    success "npiperelay.exe installed to $NPIPERELAY_PATH"
}

setup_scripts() {
    info "Copying bridge script..."
    cp "$BRIDGE_SCRIPT_NAME" "$BRIDGE_SCRIPT_PATH"
    chmod +x "$BRIDGE_SCRIPT_PATH"
    rm -f "$LEGACY_BRIDGE_SCRIPT_PATH"
    success "Bridge script installed to $BRIDGE_SCRIPT_PATH"
}

setup_systemd() {
    info "Setting up systemd service..."
    mkdir -p "$SYSTEMD_DIR"
    systemctl --user stop pki-bridge.service >/dev/null 2>&1 || true
    systemctl --user disable pki-bridge.service >/dev/null 2>&1 || true
    rm -f "$LEGACY_SERVICE_FILE_PATH"

    cp "$SERVICE_NAME" "$SERVICE_FILE_PATH"

    local systemd_path_line
    systemd_path_line=$(build_systemd_path_line)

    # Ensure PATH includes Windows executables for powershell.exe in systemd user context.
    if grep -q '^Environment=PATH=' "$SERVICE_FILE_PATH"; then
        sed -i "s|^Environment=PATH=.*|$systemd_path_line|" "$SERVICE_FILE_PATH"
    else
        info "Patching systemd service PATH for WSL interop..."
        local tmp_service
        tmp_service=$(mktemp)
        awk -v path_line="$systemd_path_line" '
            /^\[Service\]$/ { print; print path_line; next }
            { print }
        ' "$SERVICE_FILE_PATH" > "$tmp_service"
        mv "$tmp_service" "$SERVICE_FILE_PATH"
    fi

    info "Reloading systemd and enabling the service..."
    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"

    # Give it a moment to start and check status
    sleep 2
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        success "Systemd service '$SERVICE_NAME' is active."

        # Final verification check to see if keys are loaded
        info "Verifying agent connection..."
        sleep 1 # Give socat a moment to be fully ready

        # Temporarily export the variable to check the agent status
        export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"
        local check_output
        local check_status
        if check_output=$(ssh-add -l 2>&1); then
            check_status=0
        else
            check_status=$?
        fi

        if [ "$check_status" -eq 1 ] || [[ "$check_output" == *"The agent has no identities"* ]]; then
            warn "Bridge is active, but Pageant has no keys loaded."
            warn "On Windows, right-click the Pageant icon and use 'Add CAPI Cert'."
        elif [ "$check_status" -ne 0 ]; then
            warn "Bridge service is active, but agent verification returned an unexpected status."
            warn "Detail: $check_output"
        fi
    else
        warn "Systemd service failed to start. Displaying status and logs for debugging:"
        # Display status and logs on stderr to provide context for the failure.
        echo -e "\n--- Service Status ---" >&2
        systemctl --user status "$SERVICE_NAME" --no-pager --lines=10 >&2 || true
        echo -e "\n--- Service Logs (Last 5 entries) ---" >&2
        journalctl --user -u "$SERVICE_NAME" -n 5 --no-pager >&2 || true
        warn "If Pageant is not running or has no key loaded, start Pageant on Windows, add your CAPI cert, then run: systemctl --user restart $SERVICE_NAME"
        error "The service could not be started. The logs above may indicate why (e.g., Pageant not running on Windows)."
    fi
}

configure_shell() {
    info "Configuring shell environment..."
    local shell_config_files=()

    [ -f "$HOME/.bashrc" ] && shell_config_files+=("$HOME/.bashrc")
    [ -f "$HOME/.zshrc" ] && shell_config_files+=("$HOME/.zshrc")

    if [ ${#shell_config_files[@]} -eq 0 ]; then
        if [ -n "$ZSH_VERSION" ]; then
            shell_config_files+=("$HOME/.zshrc")
        elif [ -n "$BASH_VERSION" ]; then
            shell_config_files+=("$HOME/.bashrc")
        else
            warn "Could not detect .bashrc or .zshrc. You will need to add the following line to your shell's startup file manually:"
            echo -e "\n    $EXPORT_LINE\n"
            return
        fi
    fi

    local updated_any=false
    for shell_config_file in "${shell_config_files[@]}"; do
        if grep -qF "$EXPORT_LINE" "$shell_config_file" 2>/dev/null; then
            success "Shell configuration already exists in $shell_config_file."
        else
            info "Adding SSH_AUTH_SOCK to $shell_config_file..."
            sed -i -e "\|$LEGACY_SHELL_COMMENT|d" "$shell_config_file"
            echo -e "\n$SHELL_COMMENT" >> "$shell_config_file"
            echo "$EXPORT_LINE" >> "$shell_config_file"
            updated_any=true
        fi
    done

    if [ "$updated_any" = true ]; then
        success "Shell configuration updated."
    fi
}

# --- Run Script ---
main