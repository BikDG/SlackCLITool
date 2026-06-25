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
# usage: _slack_upload <channel_id> <file> [comment] [thread_ts] [name]
#   thread_ts  share the file into that thread instead of the channel root
#   name       display/filename to use instead of the file's basename
_slack_upload() {
  local channel="$1" file="$2" comment="${3:-}" thread="${4:-}" name="${5:-}"
  if [ ! -f "$file" ]; then echo "slack: file not found: $file" >&2; return 1; fi
  local size resp url fid
  [ -n "$name" ] || name="$(basename "$file")"
  size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)"
  resp="$(_slack_api files.getUploadURLExternal "filename=$name" "length=$size")"
  case "$resp" in *'"ok":true'*) ;; *) echo "slack: getUploadURL failed: $resp" >&2; return 1 ;; esac
  url="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("upload_url",""))')"
  fid="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("file_id",""))')"
  curl -s -X POST -F "file=@$file" "$url" >/dev/null
  local args=("files=[{\"id\":\"$fid\",\"title\":\"$name\"}]" "channel_id=$channel")
  [ -n "$comment" ] && args+=("initial_comment=$comment")
  [ -n "$thread" ] && args+=("thread_ts=$thread")
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

# Send a file to a channel/user (or yourself).
# usage: send_file FILE [TARGET]   (TARGET: #channel, @user, a name, or an id; -c TARGET also works)
send_file() {
  local file="$1"; shift 2>/dev/null || true
  if [ -z "$file" ]; then echo "usage: send_file FILE [TARGET]" >&2; return 1; fi
  local target=""
  if [ "$1" = "-c" ]; then target="$2"; elif [ -n "$1" ]; then target="$1"; fi
  if [ -n "$target" ]; then slack_upload -c "$target" "$file"; else slack_upload "$file"; fi
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

# Poll a conversation and print new messages as they arrive.
# usage: listen TARGET [FREQ] [-t THREAD_TS]
#   TARGET   #channel, @user, a name, or a channel/user/group id
#   FREQ     polls per minute (default 15 = every 4s)
#   -t TS    watch a single thread (its parent message ts) inside TARGET
# Runs until interrupted with Ctrl-C. Only messages posted after it starts
# are printed.
listen() {
  local thread="" pos=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) thread="$2"; shift 2 ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  local target="${pos[0]:-}" freq="${pos[1]:-15}"
  if [ -z "$target" ]; then
    echo "usage: listen TARGET [FREQ] [-t THREAD_TS]" >&2
    return 1
  fi
  case "$freq" in
    ''|*[!0-9.]*|.|*.*.*) echo "listen: FREQ must be a positive number (polls/minute)" >&2; return 1 ;;
  esac
  local interval; interval="$(awk "BEGIN{f=$freq; if(f<=0){exit 1}; printf \"%.3f\", 60/f}")" \
    || { echo "listen: FREQ must be greater than 0" >&2; return 1; }

  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then echo "listen: could not resolve target '$target'" >&2; return 1; fi

  # Build the history call once. A thread uses conversations.replies (channel+ts);
  # otherwise conversations.history over the whole conversation.
  local method="conversations.history" extra=()
  if [ -n "$thread" ]; then method="conversations.replies"; extra=("ts=$thread"); fi

  # Print messages newer than $1 (a ts), and emit the new high-water ts after a
  # sentinel as the final line. "prime" prints nothing and just returns the ts.
  # $2 is a file holding the users.list JSON (id -> display name map).
  local py='import sys, json, re, datetime
arg = sys.argv[1]
prime = (arg == "prime")
last = 0.0 if (prime or not arg) else float(arg)
umap = {}
try:
    with open(sys.argv[2]) as f:
        for u in (json.load(f) or {}).get("members", []):
            p = u.get("profile") or {}
            umap[u["id"]] = p.get("display_name") or u.get("name") or p.get("real_name") or u["id"]
except Exception:
    pass
def sub_mentions(m):
    return "@" + umap.get(m.group(1), m.group(1))
d = json.load(sys.stdin)
realmax = last
new = []
for m in d.get("messages", []):
    try:
        t = float(m.get("ts", "0"))
    except ValueError:
        continue
    if t > realmax:
        realmax = t
    if (not prime) and t > last:
        new.append((t, m))
new.sort(key=lambda x: x[0])
for t, m in new:
    who = umap.get(m.get("user", ""), m.get("username") or m.get("user") or "?")
    txt = re.sub(r"<@(\w+)>", sub_mentions, m.get("text", ""))
    when = datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S")
    print("[%s] %s: %s" % (when, who, txt))
print("@@TS@@%r" % realmax)'

  # Run the poll loop in a subshell that owns the user-map temp file, so the
  # users.list payload is read from disk (not passed via env, which can blow
  # past ARG_MAX) and is cleaned up even on Ctrl-C.
  (
    umap="$(mktemp "${TMPDIR:-/tmp}/slack-listen.XXXXXX")" || exit 1
    trap 'rm -f "$umap"' EXIT INT TERM
    _slack_api users.list "limit=1000" > "$umap"

    out="$(_slack_api "$method" "channel=$chan" "limit=200" "${extra[@]}" \
          | python3 -c "$py" prime "$umap")"
    last="${out##*@@TS@@}"

    echo "listen: watching ${target}${thread:+ thread $thread} (every ${interval}s, ${freq}/min). Ctrl-C to stop." >&2
    while :; do
      out="$(_slack_api "$method" "channel=$chan" "limit=200" "${extra[@]}" \
            | python3 -c "$py" "$last" "$umap")"
      body="${out%@@TS@@*}"
      last="${out##*@@TS@@}"
      [ -n "$body" ] && printf '%s' "$body"
      sleep "$interval"
    done
  )
}

# Recursively kill a process and all of its descendants. Used to stop the
# background `listen` that `lad` drives.
_kill_tree() {
  local pid="$1" child
  [ -n "$pid" ] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    _kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}

# Listen to a conversation and run a command when a matching message arrives.
# usage: lad [PERSON] --message STRING --command CMD [--person WHO] [--loop true|false]
#   PERSON       person/group/channel to listen to (same forms as `listen`);
#                also settable with --person; defaults to "myself" (your own DM)
#   --message    substring to watch for in incoming messages (required)
#   --command    bash command to run on a match (required)
#   --loop       true: run again on every match; false (default): stop after
#                the first match
# Flags accept either "--flag value" or "--flag=value".
# On start lad messages PERSON:
#   Listening for "<msg>" to run command "<cmd>" and loop is <True/False>.
#   Send "!quit" to end the loop.   (the !quit line only when loop is true)
# On each match it messages "running command: <cmd>", runs the command, then
# messages "command completed: <output>". In loop mode, sending "!quit" ends the
# loop and quits. It ignores its own status messages; in loop mode, pick a
# --message unlikely to appear in command output.
lad() {
  local pos="" person="" msg="" command="" loop="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --person=*)  person="${1#*=}"; shift ;;
      --person)    person="$2"; shift 2 ;;
      --message=*) msg="${1#*=}"; shift ;;
      --message)   msg="$2"; shift 2 ;;
      --command=*) command="${1#*=}"; shift ;;
      --command)   command="$2"; shift 2 ;;
      --loop=*)    loop="${1#*=}"; shift ;;
      --loop)      loop="$2"; shift 2 ;;
      *) [ -z "$pos" ] && pos="$1"; shift ;;
    esac
  done
  if [ -z "$msg" ] || [ -z "$command" ]; then
    echo "usage: lad [PERSON] --message STRING --command CMD [--loop true|false]" >&2
    return 1
  fi
  case "$loop" in true|1|yes|y|Y|True|TRUE) loop="true" ;; *) loop="false" ;; esac

  # PERSON: explicit --person wins, else positional, else default to yourself.
  local target="${person:-${pos:-myself}}" listen_target
  case "$target" in
    myself|self|me) listen_target="$(_slack_resolve "")"
      if [ -z "$listen_target" ]; then echo "lad: could not resolve your own DM" >&2; return 1; fi ;;
    *) listen_target="$target" ;;
  esac

  echo "lad: listening to $target for \"$msg\" (loop=$loop); on match runs: $command" >&2

  # Tell the user what is armed. Sent BEFORE listen starts, so listen's prime
  # step records it as already-seen and never echoes it back into the loop
  # (an exact-match guard below is a second line of defense).
  local loopdisp="False"; [ "$loop" = "true" ] && loopdisp="True"
  local announce="Listening for \"$msg\" to run command \"$command\" and loop is $loopdisp."
  [ "$loop" = "true" ] && announce="$announce Send \"!quit\" to end the loop."
  send_message "$listen_target" "$announce" >/dev/null

  # Subshell owns the fifo and the background listen, so traps are local and
  # cleanup happens on a clean exit or on Ctrl-C.
  (
    fifo="$(mktemp -u "${TMPDIR:-/tmp}/lad.XXXXXX")"
    mkfifo "$fifo" || exit 1
    lpid=""
    trap '[ -n "$lpid" ] && _kill_tree "$lpid"; rm -f "$fifo"' EXIT INT TERM
    listen "$listen_target" > "$fifo" &
    lpid=$!
    while IFS= read -r line; do
      # Strip the "[HH:MM:SS] name: " prefix so we match on message text only.
      local text="${line#*: }"
      [ "$text" = "$announce" ] && continue            # our own announce
      case "$text" in
        "running command: "*|"command completed:"*) continue ;;  # our own status echoes
      esac
      # In loop mode, "!quit" ends the loop and quits.
      if [ "$loop" = "true" ]; then
        case "$text" in
          *"!quit"*)
            send_message "$listen_target" "Stopped: received !quit." >/dev/null
            echo "lad: received !quit, stopping." >&2
            break ;;
        esac
      fi
      case "$text" in
        *"$msg"*)
          send_message "$listen_target" "running command: $command" >/dev/null
          local out; out="$(bash -c "$command" 2>&1)"
          printf '%s\n' "$out"
          send_message "$listen_target" "command completed: $out" >/dev/null
          [ "$loop" = "true" ] || break
          ;;
      esac
    done < "$fifo"
  )
}

# Watch a channel in the background and run any message that starts with "!!",
# replying in-thread with the command's output.
# usage: runitnow CHANNEL
#   CHANNEL   #channel, @user, a name, or a channel/user/group id
# Send "!!echo hi" in the channel and it runs `echo hi`, then replies to that
# message with the output. Polls once a second. Only messages posted after it
# starts are run. Commands run in a non-interactive shell that first sources
# ~/.bashrc (with alias expansion on), so functions and aliases such as `nup`
# work. Control words (first word of the message); TARGET is a watcher's pid or
# its hostname:
#   !!quit / !!stop      stop every watcher of the channel
#   !!quit TARGET        stop only watchers matching TARGET
#   !!report             each watcher replies with its pid, host, and channel
#   !!@TARGET CMD        only watchers matching TARGET run CMD (others ignore)
# A bare "!!CMD" runs on every watcher. You can also stop one from the shell
# with `kill <pid>`. WARNING: this executes arbitrary commands from the channel.
runitnow() {
  local target="$1"
  if [ -z "$target" ]; then echo "usage: runitnow CHANNEL" >&2; return 1; fi
  local chan; chan="$(_slack_resolve "$target")"
  if [ -z "$chan" ]; then echo "runitnow: could not resolve target '$target'" >&2; return 1; fi
  # Hostname to identify this instance across machines ($HOSTNAME is a bash
  # builtin var, so it works even if `hostname` is shadowed by a function).
  local host="${HOSTNAME:-$(uname -n 2>/dev/null)}"

  # For each new message whose text starts with "!!", emit
  # "RUN<tab><message ts><tab><base64 of the command>"; close with the sentinel
  # high-water ts. "prime" emits only the sentinel. base64 keeps multi-line
  # commands on a single line. Two layers of Slack mangling are undone first:
  # link markup like <http://cnn.com|cnn.com>, <@U1>, <#C1|name> is unwrapped to
  # its display text, then the &lt;/&gt;/&amp; entity escapes are reversed.
  local py='import sys, json, base64, re
arg = sys.argv[1]
prime = (arg == "prime")
last = 0.0 if (prime or not arg) else float(arg)
def unwrap(s):
    def repl(m):
        inner = m.group(1)
        if "|" in inner:
            return inner.split("|", 1)[1]
        return re.sub(r"^(mailto:|https?://|@|#|!)", "", inner)
    return re.sub(r"<([^<>]*)>", repl, s)
d = json.load(sys.stdin)
realmax = last
hits = []
for m in d.get("messages", []):
    try:
        t = float(m.get("ts", "0"))
    except ValueError:
        continue
    if t > realmax:
        realmax = t
    if (not prime) and t > last:
        txt = m.get("text", "")
        if txt.startswith("!!"):
            cmd = unwrap(txt[2:]).replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
            hits.append((t, m.get("ts", ""), base64.b64encode(cmd.encode()).decode()))
hits.sort(key=lambda x: x[0])
for t, ts, b in hits:
    print("RUN\t%s\t%s" % (ts, b))
print("@@TS@@%r" % realmax)'

  (
    mypid="$BASHPID"   # this watcher's pid (used in replies from async workers)
    # Per-instance registry of currently running command workers: one file per
    # worker, named by worker pid, containing the command. Used by !!report.
    taskdir="${TMPDIR:-/tmp}/runitnow-tasks-$mypid"
    mkdir -p "$taskdir"
    # When this watcher stops, kill any still-running command workers (e.g. an
    # un-capped ping) and drop the registry instead of orphaning them.
    _rin_stop() { trap - EXIT INT TERM; for _p in $(jobs -p); do _kill_tree "$_p" 2>/dev/null; done; rm -rf "$taskdir"; exit; }
    trap _rin_stop EXIT INT TERM
    last="$(_slack_api conversations.history "channel=$chan" "limit=200" | python3 -c "$py" prime)"
    last="${last##*@@TS@@}"
    while :; do
      out="$(_slack_api conversations.history "channel=$chan" "limit=200" | python3 -c "$py" "$last")"
      last="${out##*@@TS@@}"
      body="${out%@@TS@@*}"
      if [ -n "$body" ]; then
        while IFS="$(printf '\t')" read -r tag ts b64; do
          [ "$tag" = "RUN" ] || continue
          cmd="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
          # Reserved control words, matched on the first word of the message.
          # A "target" below is this instance's pid or its hostname:
          #   !!quit / !!stop           -> every watcher of this channel stops
          #   !!quit TARGET             -> only watchers matching TARGET stop
          #   !!report                  -> each watcher replies with pid + host
          #   !!@TARGET CMD             -> only watchers matching TARGET run CMD
          # Split with read (IFS reset to whitespace; the outer loop's IFS is a
          # tab) rather than `tr`, which a user may have shadowed with a function.
          IFS=$' \t' read -r kw arg _rest <<< "$cmd"
          case "$kw" in
            quit|stop)
              if [ -z "$arg" ] || [ "$arg" = "$mypid" ] || [ "${arg,,}" = "${host,,}" ]; then
                _slack_api chat.postMessage "channel=$chan" "thread_ts=$ts" "text=runitnow: stopped (pid $mypid on $host)." >/dev/null
                exit 0
              fi
              continue ;;   # target given but not us: stay silent, keep running
            report)
              # Roll up this instance's currently running command workers.
              tasks="" ; n=0
              for tf in "$taskdir"/*; do
                [ -e "$tf" ] || continue
                n=$((n + 1))
                tcmd="$(<"$tf")"; tcmd="${tcmd//$'\n'/ }"; tcmd="${tcmd:0:200}"
                tasks="$tasks"$'\n'"[${tf##*/}] $tcmd"
              done
              rtext="runitnow: pid $mypid on $host watching $target — running tasks ($n):"
              [ "$n" -gt 0 ] && rtext="$rtext"$'\n''```'"$tasks"$'\n''```'
              _slack_api chat.postMessage "channel=$chan" "thread_ts=$ts" "text=$rtext" >/dev/null
              continue ;;
            @*)
              # Targeted command: skip unless TARGET is our pid or hostname...
              local tgt="${kw#@}"
              if [ "$tgt" != "$mypid" ] && [ "${tgt,,}" != "${host,,}" ]; then continue; fi
              # ...then strip the "@TARGET" token, leaving the real command in cmd.
              local lt="${cmd#"${cmd%%[![:space:]]*}"}"
              cmd="${lt#"$kw"}"
              cmd="${cmd#"${cmd%%[![:space:]]*}"}"
              ;;
          esac
          # Run each command in its own background worker so a long-running one
          # (e.g. an un-capped `ping`) doesn't block the watcher from handling
          # other messages. Variables are snapshotted at fork, so each worker
          # carries its own cmd/ts.
          (
            wpid="$BASHPID"
            printf '%s\n' "$cmd" >"$taskdir/$wpid" 2>/dev/null   # register running task
            # Non-interactive shell, but source ~/.bashrc (alias expansion on) so
            # functions/aliases like `nup` work; sourcing output is discarded.
            # Capture to a file (not "$(...)") with stdin closed so a command
            # that backgrounds a child can't hold a pipe open.
            cf="$(mktemp "${TMPDIR:-/tmp}/runitnow.XXXXXX")"
            RUNITNOW_CMD="$cmd" bash -c '
              shopt -s expand_aliases
              [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" >/dev/null 2>&1
              eval "$RUNITNOW_CMD"' </dev/null >"$cf" 2>&1
            cout="$(cat "$cf")"
            [ -n "$cout" ] || cout="(no output)"
            # Cap the inlined output (Slack message + ~128 KB exec-arg limits);
            # attach the full output as a thread file when it was truncated.
            big=0
            if [ "${#cout}" -gt 3000 ]; then
              cout="${cout:0:3000}"$'\n'"... (truncated; full output was ${#cout} chars — see attached file)"
              big=1
            fi
            reply="$mypid running on machine $host replies:"$'\n''```'$'\n'"$cout"$'\n''```'
            _slack_api chat.postMessage "channel=$chan" "thread_ts=$ts" "text=$reply" >/dev/null
            [ "$big" -eq 1 ] && _slack_upload "$chan" "$cf" "full output from pid $mypid on $host" "$ts" "output-$mypid-$host.txt" >/dev/null 2>&1
            rm -f "$cf" "$taskdir/$wpid"
          ) &
        done <<EOF
$body
EOF
      fi
      sleep 1
    done
  ) &
  echo "runitnow: $host watching $target every 1s for '!!' commands (pid $!). '!!report' lists instances, '!!quit' stops all, '!!quit $!' stops this one, '!!@$host CMD' targets this host (or: kill $!)"
}
