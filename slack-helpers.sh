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

# Resolve @name / name -> user id (exact, then prefix, then substring match).
_slack_user_id() {
  _slack_api users.list "limit=1000" | python3 -c \
'import sys,json
n=sys.argv[1].lstrip("@").lower()
d=json.load(sys.stdin)
def names(u):
    p=u.get("profile") or {}
    vals=[(u.get("name") or "").lower(),(p.get("display_name") or "").lower(),(p.get("real_name") or "").lower()]
    return [v for v in vals if v]
members=[u for u in d.get("members",[]) if not u.get("deleted")]
for test in (lambda v: v==n, lambda v: v.startswith(n), lambda v: n in v):
    for u in members:
        if any(test(v) for v in names(u)):
            print(u["id"]); sys.exit()
print("")' "$1"
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
    *)   local u; u="$(_slack_user_id "$t")"; [ -n "$u" ] && _slack_open_im "$u" ;;
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

# Send a message to a channel or user (positional target). Sugar over slack_send.
# usage: send_message TARGET MESSAGE...
#   TARGET   #channel, @user, a name, or a channel/user id
send_message() {
  local target="$1"; shift 2>/dev/null || true
  if [ -z "$target" ] || [ -z "$*" ]; then
    echo "usage: send_message TARGET MESSAGE..." >&2
    return 1
  fi
  slack_send -c "$target" "$@"
}

# Internal: upload a file to a resolved channel id.
# usage: _slack_upload <channel_id> <file> [comment]
_slack_upload() {
  local channel="$1" file="$2" comment="${3:-}"
  if [ ! -f "$file" ]; then echo "slack: file not found: $file" >&2; return 1; fi
  local name size resp url fid
  name="$(basename "$file")"
  size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)"
  resp="$(_slack_api files.getUploadURLExternal "filename=$name" "length=$size")"
  case "$resp" in *'"ok":true'*) ;; *) echo "slack: getUploadURL failed: $resp" >&2; return 1 ;; esac
  url="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("upload_url",""))')"
  fid="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("file_id",""))')"
  curl -s -X POST -F "file=@$file" "$url" >/dev/null
  local args=("files=[{\"id\":\"$fid\",\"title\":\"$name\"}]" "channel_id=$channel")
  [ -n "$comment" ] && args+=("initial_comment=$comment")
  resp="$(_slack_api files.completeUploadExternal "${args[@]}")"
  case "$resp" in *'"ok":true'*) return 0 ;; *) echo "slack: completeUpload failed: $resp" >&2; return 1 ;; esac
}

# Upload a file to Slack.
# usage: slack_upload [-c TARGET] [-m COMMENT] FILE
slack_upload() {
  local target="" comment=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c) target="$2"; shift 2 ;;
      -m) comment="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local file="$1"
  if [ -z "$file" ]; then echo "usage: slack_upload [-c TARGET] [-m COMMENT] FILE" >&2; return 1; fi
  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then echo "slack_upload: could not resolve target '${target:-self}'" >&2; return 1; fi
  _slack_upload "$chan" "$file" "$comment" && echo "slack: uploaded $(basename "$file") to ${target:-self}"
}

# Send a file to your own DM. usage: save_file FILE
save_file() {
  if [ -z "$1" ]; then echo "usage: save_file FILE" >&2; return 1; fi
  slack_upload -m "uploaded $(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Send a file to a channel/user (or yourself). usage: send_file FILE [-c TARGET]
send_file() {
  local file="$1"; shift 2>/dev/null || true
  if [ -z "$file" ]; then echo "usage: send_file FILE [-c #channel|@user|ID]" >&2; return 1; fi
  slack_upload "$@" "$file"
}

# List recent files in a channel (your own DM by default).
# usage: list_files [-c TARGET] [-n COUNT]
list_files() {
  local target="" count=50
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c) target="$2"; shift 2 ;;
      -n) count="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then echo "list_files: could not resolve target '${target:-self}'" >&2; return 1; fi
  local resp; resp="$(_slack_api files.list "channel=$chan" "count=$count")"
  case "$resp" in *'"ok":true'*) ;; *) echo "slack: files.list failed: $resp" >&2; return 1 ;; esac
  printf '%s' "$resp" | python3 -c \
'import sys,json
d=json.load(sys.stdin)
fs=d.get("files",[])
print(str(len(fs))+" file(s) in "+sys.argv[1]+":")
for f in fs:
    print("  %s  (%s bytes, id %s)" % (f.get("name"), f.get("size",0), f.get("id")))' "${target:-self}"
}

# Download a file (most recent match by name) from a channel to a local path.
# usage: fetch_file REMOTE_NAME [LOCAL_PATH] [-c TARGET]
fetch_file() {
  local target="" pos=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c) target="$2"; shift 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local name="${pos[0]:-}" dest="${pos[1]:-${pos[0]:-}}"
  if [ -z "$name" ]; then echo "usage: fetch_file REMOTE_NAME [LOCAL_PATH] [-c TARGET]" >&2; return 1; fi
  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then echo "fetch_file: could not resolve target '${target:-self}'" >&2; return 1; fi
  local resp; resp="$(_slack_api files.list "channel=$chan" "count=200")"
  case "$resp" in *'"ok":true'*) ;; *) echo "slack: files.list failed: $resp" >&2; return 1 ;; esac
  local url; url="$(printf '%s' "$resp" | python3 -c \
'import sys,json
name=sys.argv[1]
d=json.load(sys.stdin)
m=[f for f in d.get("files",[]) if f.get("name")==name]
m.sort(key=lambda f: f.get("created",0), reverse=True)
print(m[0].get("url_private_download","") if m else "")' "$name")"
  if [ -z "$url" ]; then echo "fetch_file: no file named '$name' in ${target:-self}" >&2; return 1; fi
  local code; code="$(curl -s -H "Cookie: d=$SLACK_XOXD;" -o "$dest" -w '%{http_code}' "$url")"
  if [ "$code" = "200" ]; then
    echo "fetch_file: saved $name -> $dest"
  else
    echo "fetch_file: download failed (HTTP $code)" >&2; rm -f "$dest"; return 1
  fi
}

# Run a command, then Slack you its result and full output.
# usage: lmk [-c TARGET] COMMAND [args...]
lmk() {
  local target=""
  if [ "$1" = "-c" ]; then target="$2"; shift 2; fi
  if [ "$#" -eq 0 ]; then echo "usage: lmk [-c TARGET] COMMAND [args...]" >&2; return 1; fi
  local tmp start status dur msg last chan
  tmp="$(mktemp "${TMPDIR:-/tmp}/lmk.XXXXXX")"
  start="$(date +%s)"
  "$@" 2>&1 | tee "$tmp"
  status="${PIPESTATUS[0]}"
  dur=$(( $(date +%s) - start ))
  if [ "$status" -eq 0 ]; then
    msg=":white_check_mark: succeeded: $* (${dur}s)"
  else
    msg=":x: failed (exit $status): $* (${dur}s)"
  fi
  last="$(tail -25 "$tmp")"
  [ -n "$last" ] && msg="$msg"$'\n''```'$'\n'"$last"$'\n''```'
  chan="$(_slack_resolve "$target")"
  if [ -n "$chan" ]; then
    _slack_api chat.postMessage "channel=$chan" "text=$msg" >/dev/null
    _slack_upload "$chan" "$tmp" "output of: $*" >/dev/null 2>&1
  else
    echo "lmk: could not resolve target '${target:-self}'" >&2
  fi
  rm -f "$tmp"
  return "$status"
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
