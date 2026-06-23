#!/usr/bin/env bash
# Installer for slack-session-cli. Idempotent: safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
SHARE="$HOME/.local/share/slack-session-cli"
MARK_START="# >>> slack-session-cli >>>"
MARK_END="# <<< slack-session-cli <<<"

# Pick the right shell rc file.
RC="$HOME/.bashrc"
case "${SHELL:-}" in
  */zsh) RC="$HOME/.zshrc" ;;
esac

echo "Installing slack-session-cli..."

# Dependency checks.
missing=""
for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [ -n "$missing" ]; then
  echo "  WARNING: missing required commands:$missing" >&2
fi
if ! python3 -c 'import snappy' >/dev/null 2>&1; then
  echo "  NOTE: python 'snappy' module not found. If slack-refresh fails to read" >&2
  echo "        the token, install it with: pip install --user python-snappy" >&2
fi

mkdir -p "$BIN" "$SHARE"
install -m 755 "$HERE/slack-refresh"   "$BIN/slack-refresh"
install -m 644 "$HERE/slack-helpers.sh" "$SHARE/slack-helpers.sh"
echo "  installed slack-refresh   -> $BIN/slack-refresh"
echo "  installed slack-helpers.sh -> $SHARE/slack-helpers.sh"

if grep -qF "$MARK_START" "$RC" 2>/dev/null; then
  echo "  source block already present in $RC"
else
  {
    echo ""
    echo "$MARK_START"
    echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
    echo '[ -f "$HOME/.local/share/slack-session-cli/slack-helpers.sh" ] && . "$HOME/.local/share/slack-session-cli/slack-helpers.sh"'
    echo "$MARK_END"
  } >> "$RC"
  echo "  added source block to $RC"
fi

cat <<EOF

Done. Next steps:
  1) Open a new shell, or run: source $RC
  2) Log into Slack in Firefox.
  3) Run: slack-refresh
  4) Test: slack_send 'hello from slack-session-cli'

Commands: slack_send, send_message, slack_upload, save_file, send_file,
          list_files, fetch_file, lmk, notify_up (alias: nup), slack-refresh.
Read the README for usage and the security caveats.
EOF
