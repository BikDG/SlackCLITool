# slack-session-cli helpers. Sourced from your shell rc by install.sh.
# Sends Slack messages as your own browser session (xoxc token + d cookie),
# loaded from ~/.slack_session (written by `slack-refresh`).

[ -f "$HOME/.slack_session" ] && . "$HOME/.slack_session"

# Low-level Slack Web API call: token in the body, d cookie in a header.
# xoxc tokens do NOT work as Authorization: Bearer headers.
# usage: _slack_api <method> [field=value ...]   (prints raw JSON)
_slack_api() {
  local method="$1"; shift
  if [ -z "$SLACK_XOXC" ] || [ -z "$SLACK_XOXD" ]; then
    echo "slack: no session loaded. Log into Slack in Firefox, then run: slack-refresh" >&2
    return 1
  fi
  local args=(--data-urlencode "token=$SLACK_XOXC") kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -s -H "Cookie: d=$SLACK_XOXD;" "${args[@]}" "https://slack.com/api/$method"
}

# Open (or fetch) the DM channel id for a user id.
_slack_open_im() {
  _slack_api conversations.open "users=$1" | python3 -c \
'import sys,json
d=json.load(sys.stdin)
print((d.get("channel") or {}).get("id","") if d.get("ok") else "")'
}

# Resolve @name / name -> user id.
_slack_user_id() {
  _slack_api users.list "limit=1000" | python3 -c \
'import sys,json
n=sys.argv[1].lstrip("@").lower()
d=json.load(sys.stdin)
def names(u):
    p=u.get("profile") or {}
    return [(u.get("name") or "").lower(),(p.get("display_name") or "").lower(),(p.get("real_name") or "").lower()]
print(next((u["id"] for u in d.get("members",[]) if n in names(u)),""))' "$1"
}

# Resolve #name -> channel id.
_slack_chan_id() {
  _slack_api conversations.list "types=public_channel,private_channel" "limit=1000" | python3 -c \
'import sys,json
n=sys.argv[1].lstrip("#").lower()
d=json.load(sys.stdin)
print(next((c["id"] for c in d.get("channels",[]) if (c.get("name") or "").lower()==n),""))' "$1"
}

# Resolve a target to a postable channel id.
#   ""            -> your own DM
#   #channel      -> channel id by name
#   @user / name  -> that user's DM
#   C.../D.../G... -> passed through (channel/dm/group id)
#   U.../W...      -> that user's DM
_slack_resolve() {
  local t="$1" me
  case "$t" in
    "")
      me="${SLACK_USER_ID:-$(_slack_api auth.test | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user_id",""))')}"
      [ -n "$me" ] && _slack_open_im "$me" ;;
    \#*) _slack_chan_id "$t" ;;
    @*)  local u; u="$(_slack_user_id "$t")"; [ -n "$u" ] && _slack_open_im "$u" ;;
    C*|D*|G*) echo "$t" ;;
    U*|W*) _slack_open_im "$t" ;;
    *)   local u; u="$(_slack_user_id "$t")"; if [ -n "$u" ]; then _slack_open_im "$u"; else echo "$t"; fi ;;
  esac
}

# Send a Slack message.
# usage: slack_send [-c TARGET] MESSAGE...
#   -c TARGET   #channel, @user, a channel/user id, or omit for your own DM
slack_send() {
  local target=""
  if [ "$1" = "-c" ]; then target="$2"; shift 2; fi
  local msg="$*"
  if [ -z "$msg" ]; then
    echo "usage: slack_send [-c #channel|@user|ID] MESSAGE..." >&2
    return 1
  fi
  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then
    echo "slack_send: could not resolve target '${target:-self}'" >&2
    return 1
  fi
  local resp; resp="$(_slack_api chat.postMessage "channel=$chan" "text=$msg")"
  case "$resp" in
    *'"ok":true'*) echo "slack: sent to ${target:-self}" ;;
    *) echo "slack: send failed: $resp" >&2; return 1 ;;
  esac
}

# Ping a host until it replies, then send a Slack message (to yourself by default).
# usage: notify_up <host> [-c TARGET]
notify_up() {
  local host="$1"; shift
  if [ -z "$host" ]; then
    echo "usage: notify_up <host> [-c #channel|@user|ID]" >&2
    return 1
  fi
  ( until ping -c1 -W2 "$host" >/dev/null 2>&1; do sleep 5; done
    slack_send "$@" "✅ $host is up ($(date '+%Y-%m-%d %H:%M:%S'))" >/dev/null 2>&1 ) &
  echo "watching $host (pid $!). Will message you when it replies."
}
alias nup='notify_up'
