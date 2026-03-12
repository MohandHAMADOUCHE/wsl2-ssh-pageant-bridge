#!/bin/bash

# --- CONFIGURATION ---
export SSH_AUTH_SOCK="$HOME/.ssh/wsl-ssh-agent.sock"
NPIPERELAY_PATH="$HOME/.local/bin/npiperelay.exe"
SOCAT_LOG="${TMPDIR:-/tmp}/wsl2-ssh-pageant-bridge-socat.log"
NPIPERELAY_CACHE_DIR="$HOME/.cache/wsl2-ssh-pageant-bridge"

# Détection du mode verbeux
VERBOSE=false
[[ "$1" == "-v" ]] && VERBOSE=true

# 1. Nettoyage
killall socat npiperelay.exe 2>/dev/null
rm -f "$SSH_AUTH_SOCK"
mkdir -p "$(dirname "$SSH_AUTH_SOCK")"

# 2. Détection du Pipe Pageant
PIPE_NAME=$(powershell.exe -Command "(Get-ChildItem \\\\.\\pipe\\ | Where-Object { \$_.Name -like '*pageant*' } | Select-Object -First 1).Name" 2>/dev/null | tr -d '\r')

# ERREUR : Pageant non trouvé (TOUJOURS AFFICHÉ)
if [ -z "$PIPE_NAME" ]; then
    echo "❌ Erreur : Pageant (Windows) n'est pas détecté. Vérifiez qu'il est lancé."
    return 1 2>/dev/null || exit 1
fi

CLEAN_PIPE="//./pipe/$PIPE_NAME"

# ERREUR : Binaire manquant (TOUJOURS AFFICHÉ)
if [ ! -f "$NPIPERELAY_PATH" ]; then
    ALT_NPIPERELAY_PATH=$(command -v npiperelay.exe 2>/dev/null || command -v npiperelay 2>/dev/null)
    if [ -n "$ALT_NPIPERELAY_PATH" ] && [ -f "$ALT_NPIPERELAY_PATH" ]; then
        NPIPERELAY_PATH="$ALT_NPIPERELAY_PATH"
    else
        echo "❌ Erreur : npiperelay.exe introuvable dans $NPIPERELAY_PATH"
        return 1 2>/dev/null || exit 1
    fi
fi

# Rendre npiperelay exécutable (ou utiliser une copie utilisateur si le fichier est root-owned)
if [ ! -x "$NPIPERELAY_PATH" ]; then
    if [ -w "$NPIPERELAY_PATH" ]; then
        chmod +x "$NPIPERELAY_PATH" 2>/dev/null || true
    fi

    if [ ! -x "$NPIPERELAY_PATH" ]; then
        mkdir -p "$NPIPERELAY_CACHE_DIR"
        USER_NPIPERELAY_PATH="$NPIPERELAY_CACHE_DIR/npiperelay.exe"
        cp "$NPIPERELAY_PATH" "$USER_NPIPERELAY_PATH" 2>/dev/null || {
            echo "❌ Erreur : npiperelay.exe n'est pas exécutable et la copie locale a échoué."
            echo "👉 ACTION : Exécutez 'sudo chmod +x $NPIPERELAY_PATH' puis relancez."
            return 1 2>/dev/null || exit 1
        }
        chmod +x "$USER_NPIPERELAY_PATH" 2>/dev/null || {
            echo "❌ Erreur : Impossible de rendre exécutable $USER_NPIPERELAY_PATH"
            return 1 2>/dev/null || exit 1
        }
        NPIPERELAY_PATH="$USER_NPIPERELAY_PATH"
    fi
fi

# 3. Lancement du pont
rm -f "$SOCAT_LOG"
nohup socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork EXEC:"$NPIPERELAY_PATH -ei -s $CLEAN_PIPE",nofork >"$SOCAT_LOG" 2>&1 &

# Attente courte de création du socket (évite les faux négatifs au démarrage)
for _ in {1..30}; do
    [ -S "$SSH_AUTH_SOCK" ] && break
    sleep 0.1
done

if [ ! -S "$SSH_AUTH_SOCK" ]; then
    echo "❌ ERREUR : Socket SSH non créé ($SSH_AUTH_SOCK)."
    [ -s "$SOCAT_LOG" ] && echo "Détail socat: $(tail -n 1 "$SOCAT_LOG")"
    return 1 2>/dev/null || exit 1
fi

# 4. Vérification de l'état des clés
CHECK_KEYS=$(ssh-add -l 2>&1)
CHECK_STATUS=$?

if [ "$CHECK_STATUS" -eq 0 ]; then
    # SUCCÈS : Affichage uniquement si -v est présent
    if [ "$VERBOSE" = true ]; then
        echo "✅ Pont PKI activé sur : $CLEAN_PIPE"
        echo "🔑 CLÉ(S) DÉTECTÉE(S) :"
        echo "$CHECK_KEYS"
    fi
elif [ "$CHECK_STATUS" -eq 1 ]; then
    # AGENT VIDE : On affiche toujours l'alerte
    echo "⚠️  AGENT VIDE : Le pont fonctionne mais aucune clé n'est détectée."
    echo "👉 ACTION : Sous Windows, faites Clic-droit sur Pageant -> 'Add CAPI cert'."
else
    # ERREUR DE COM : code retour 2 (ou autre inattendu)
    echo "❌ ERREUR : Problème de communication avec l'agent SSH."
    [ "$VERBOSE" = true ] && echo "Détail ssh-add : $CHECK_KEYS"
fi
