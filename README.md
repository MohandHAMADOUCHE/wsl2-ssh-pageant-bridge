<p align="center">
	<img src="logo.svg" alt="WSL2 SSH Pageant Bridge logo" width="900" />
</p>

# 🛡️ WSL2 SSH Pageant Bridge

**A robust bridge to use Windows Pageant (smart card/certificate) keys from WSL 2.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: WSL 2](https://img.shields.io/badge/Platform-WSL%202-blue.svg)](https://docs.microsoft.com/en-us/windows/wsl/)

`WSL2 SSH Pageant Bridge` forwards Pageant identities into WSL through a Unix socket, so SSH/Git in Linux can use hardware-backed keys managed on Windows.

---

## 🎯 Why this exists

WSL cannot directly consume Windows Pageant identities. This project creates a bridge:

`SSH client (WSL)` ↔ `SSH_AUTH_SOCK` ↔ `socat` ↔ `npiperelay.exe` ↔ `Windows named pipe` ↔ `Pageant`

Component roles:

- `SSH client (WSL)`: tools such as `ssh`, `git`, or `ssh-add` that expect to talk to an SSH agent from inside Linux.
- `SSH_AUTH_SOCK`: the Unix socket path exported in your shell so Linux tools know where the SSH agent is reachable.
- `socat`: the local relay process that listens on the Unix socket and forwards requests to the Windows side.
- `npiperelay.exe`: the bridge binary that converts Linux-side traffic into Windows named pipe traffic.
- `Windows named pipe`: the Windows IPC channel used by Pageant to expose its agent interface.
- `Pageant`: the Windows SSH agent holding your smart card/CAPI-backed identities and answering authentication requests without exporting private keys into WSL.

---

## ✅ What the current version handles

- Automatic install of dependencies (`socat`, `curl`, `unzip`) when missing.
- Multi-distro package manager support in installer (`apt`, `dnf`, `pacman`, `zypper`).
- Systemd user service configured for WSL interop (`powershell.exe` reachable from service environment).
- Reliable service behavior with `Type=oneshot` + `RemainAfterExit=yes` (no restart loop).
- Shell config update in **both** `~/.bashrc` and `~/.zshrc` when present.
- Uninstall cleanup in **both** `~/.bashrc` and `~/.zshrc`.
- Fallback when `npiperelay.exe` is not executable/owned by root (user-local executable copy).

---

## 📋 Prerequisites

### Windows
- [Pageant](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) running.
- Your certificate loaded in Pageant (`Add CAPI cert`).

### WSL
- WSL interop enabled (default in most setups).
- user systemd enabled.
- Internet access if installer needs to download `npiperelay`.

### If WSL interop is disabled

This project needs Windows executables to be callable from WSL, especially `powershell.exe`.

Quick check:

```bash
command -v powershell.exe
```

If this returns nothing, check `/etc/wsl.conf` and make sure interop is enabled:

```ini
[interop]
enabled=true
appendWindowsPath=true
```

Then restart WSL from Windows:

```powershell
wsl --shutdown
```

Open WSL again and verify:

```bash
command -v powershell.exe
```

---

## 🚀 Installation (recommended)

`install.sh` automatically downloads `npiperelay.exe` from GitHub (release asset), then installs it into `~/.local/bin`.

Primary download URL used by the installer:

`https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip`

```bash
git clone https://github.com/MohandHAMADOUCHE/wsl2-ssh-pageant-bridge.git
cd wsl2-ssh-pageant-bridge
chmod +x install.sh
./install.sh
```

After install:
- Open a new terminal, or run `source ~/.bashrc` / `source ~/.zshrc`.
- Verify with:

```bash
ssh-add -l
```

If the bridge works, you should see your Pageant/CAPI key.

---

## ▶️ Usage after installation

1. Check the service status:

```bash
systemctl --user status wsl2-ssh-pageant-bridge.service --no-pager
```

2. Check agent visibility:

```bash
ssh-add -l
```

3. If Pageant is not active:
- Start **Pageant** on Windows.
- In Pageant, load your certificate/key (`Add CAPI cert`).

4. Restart and verify again from WSL:

```bash
systemctl --user restart wsl2-ssh-pageant-bridge.service
systemctl --user status wsl2-ssh-pageant-bridge.service --no-pager
ssh-add -l
```

---

## ⚙️ Manual installation (advanced)

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user
cp wsl2-ssh-pageant-bridge.sh ~/.local/bin/wsl2-ssh-pageant-bridge.sh
cp wsl2-ssh-pageant-bridge.service ~/.config/systemd/user/wsl2-ssh-pageant-bridge.service
chmod +x ~/.local/bin/wsl2-ssh-pageant-bridge.sh
```

Ensure `npiperelay.exe` exists at `~/.local/bin/npiperelay.exe` (or in your `PATH`), then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wsl2-ssh-pageant-bridge.service
```

And set:

```bash
export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"
```

---

## 🐚 Shell behavior

The installer appends this line to both shell rc files (if they exist):

```bash
export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"
```

This is intentionally appended at the end, so it overrides earlier `gpg-agent`/`ssh-agent` socket exports.

---

## 🛠️ Troubleshooting

### 1) Check service and logs

```bash
systemctl --user status wsl2-ssh-pageant-bridge.service --no-pager
journalctl --user -u wsl2-ssh-pageant-bridge.service -n 20 --no-pager
```

### 2) Check socket + key visibility

```bash
echo "$SSH_AUTH_SOCK"
ls -l "$SSH_AUTH_SOCK"
ssh-add -l
```

### 3) Common cases

| Symptom | Meaning | Fix |
| :--- | :--- | :--- |
| `❌ Erreur : Pageant (Windows) n'est pas détecté.` | Pageant pipe not visible from WSL/service context. | Start Pageant on Windows; verify service PATH and WSL interop. |
| `⚠️ AGENT VIDE` | Bridge is up, but no key loaded in Pageant. | In Windows Pageant: `Add CAPI cert`. |
| `Permission denied` for `npiperelay.exe` | Non-executable binary (often root-owned). | Re-run installer or `chmod +x ~/.local/bin/npiperelay.exe`; script also has a user-cache fallback. |
| `Error connecting to agent: No such file or directory` after `source ~/.bashrc` | `SSH_AUTH_SOCK` points to missing socket or was overridden. | Ensure service is running and rc ends with bridge export; open new shell/re-source rc. |
| `ssh-add -l` → `error fetching identities: communication with agent failed` | Pageant is not running (or bridge lost communication). | Start Pageant on Windows, load your cert/key, then run `systemctl --user restart wsl2-ssh-pageant-bridge.service` and retry `ssh-add -l`. |

If interop is disabled, `powershell.exe` will not be available inside WSL and the bridge cannot detect Pageant.

### 4) If the service fails during installation

If installation shows something like:

```text
Mar 11 18:14:22 ... wsl2-ssh-pageant-bridge.service: Failed with result 'exit-code'.
Mar 11 18:14:22 ... Failed to start wsl2-ssh-pageant-bridge.service - WSL2 SSH Pageant Bridge.
```

do the following:

1. Start **Pageant** on Windows.
2. Make sure your certificate is loaded in Pageant.
3. Restart the user service from WSL:

```bash
systemctl --user start wsl2-ssh-pageant-bridge.service
```

4. Verify the service status:

```bash
systemctl --user status wsl2-ssh-pageant-bridge.service --no-pager
```

5. Verify key visibility:

```bash
ssh-add -l
```

---

## 🧹 Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Uninstall does the following:
- Stops/disables the user systemd service.
- Removes service/script/binary files installed by this project.
- Removes bridge export line from both `~/.bashrc` and `~/.zshrc`.

After uninstall, open a new shell (or `source` your rc file) to return to your local SSH/GPG agent setup.

