#!/usr/bin/env bash
# Uninstaller for slack-session-cli.
set -euo pipefail

BIN="$HOME/.local/bin"
SHARE="$HOME/.local/share/slack-session-cli"

RC="$HOME/.bashrc"
case "${SHELL:-}" in
  */zsh) RC="$HOME/.zshrc" ;;
esac

echo "Removing slack-session-cli..."

if [ -f "$RC" ]; then
  # Delete the marker block.
  tmp="$(mktemp)"
  sed '/# >>> slack-session-cli >>>/,/# <<< slack-session-cli <<</d' "$RC" > "$tmp"
  cat "$tmp" > "$RC"
  rm -f "$tmp"
  echo "  removed source block from $RC"
fi

rm -f "$BIN/slack-refresh" "$SHARE/slack-helpers.sh"
rmdir "$SHARE" 2>/dev/null || true
echo "  removed installed files"

echo
echo "Left in place: ~/.slack_session (your session credentials)."
echo "Delete it yourself if you want them gone:  rm -f ~/.slack_session"
