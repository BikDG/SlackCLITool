# slack-session-cli

Send Slack messages from your terminal without a Slack app or bot token.

It authenticates as your own Slack browser session, reusing the `xoxc` token and
`d` cookie that Firefox already holds after you log in. This is useful when your
workspace has disabled app creation and you cannot mint a bot token, but you can
still log into Slack in a browser.

## What you get

- `slack_send` — send a message to yourself, a channel, or a user.
- `send_message` — message a user or channel by name (positional form of `slack_send`).
- `slack_upload` — upload a file (with `save_file` and `send_file` as shortcuts).
- `list_files` / `fetch_file` — list and download files from a channel or your DM.
- `lmk` — run a command, then Slack you its result and full output.
- `listen` — poll a channel, DM, group, or thread and print new messages as they arrive.
- `lad` — listen for a message matching a string, then run a command (once or on every match).
- `runitnow` — background watcher that runs any `!!command` posted in a channel and replies in-thread.
- `notify_up` (alias `nup`) — ping a host until it replies, then message you.
- `slack-refresh` — re-read the session from Firefox into `~/.slack_session`.

## Requirements

- Linux or macOS, with Firefox logged into Slack.
- `bash`, `curl`, and `python3`.
- The python `snappy` module, only if your Firefox compresses localStorage:
  `pip install --user python-snappy`.

Firefox specifically, because it stores cookies and localStorage in plaintext
SQLite. Chrome encrypts its cookie store, so this tool does not read it.

## Install

```sh
./install.sh
```

This copies `slack-refresh` to `~/.local/bin`, copies the helpers to
`~/.local/share/slack-session-cli`, and adds a source block to your shell rc.
Then:

```sh
source ~/.bashrc      # or open a new shell
slack-refresh         # after logging into Slack in Firefox
slack_send 'it works'
```

## Usage

```sh
slack_send 'message to myself'             # your own DM
slack_send -c '#general' 'message'         # a channel by name
slack_send -c @alice 'message'             # a user by name
slack_send -c C0123456789 'message'        # a channel by id
send_message @alice 'message'              # positional target form
send_message pablo 'message'               # names match fuzzily

notify_up build-server                     # DM yourself when the host pings
notify_up build-server -c '#builds'        # message a channel instead
nup build-server                           # same, short alias
```

Files and command output:

```sh
save_file report.pdf                       # upload a file to your own DM
send_file report.pdf pablo                 # upload to a user (positional target)
send_file report.pdf '#team'               # upload to a channel
slack_upload -c @alice -m 'see this' x.log # upload with a comment

list_files                                 # files in your own DM
list_files -c '#team' -n 100               # files in a channel
fetch_file report.pdf                      # download newest match from your DM
fetch_file report.pdf out.pdf -c '#team'   # from a channel, to a local path

lmk make                                   # run `make`, then DM you pass/fail
lmk -c '#builds' ./deploy.sh               # report the result to a channel
```

`lmk` streams the command's output to your terminal as usual, then sends a
pass/fail summary with the last 25 lines and attaches the full output as a file.

Watch a conversation live:

```sh
listen @alice                              # poll a user's DM every 4s
listen '#team'                             # poll a channel
listen pablo 30                            # 30 polls/minute (every 2s)
listen '#team' -t 1718900000.123456        # watch one thread by its parent ts
```

`listen` prints only messages posted after it starts, one per line as
`[HH:MM:SS] name: text`. The frequency is polls per minute (default 15, i.e.
every 4 seconds). It runs in the foreground until you stop it with Ctrl-C.

Listen and do — run a command when a matching message arrives:

```sh
lad --message deploy --command './deploy.sh'                # watch your own DM
lad @alice --message deploy --command './deploy.sh'         # fire once, then stop
lad --person '#ops' --message restart --loop true --command 'systemctl restart app'
```

`lad` watches a person/group with `listen` and, when an incoming message
contains the `--message` string, messages them `running command: <cmd>`, runs
the command, then messages `command completed: <output>`. On start it messages
them `Listening for "<msg>" to run command "<cmd>" and loop is <True/False>.`,
adding `Send "!quit" to end the loop.` when looping.

The person defaults to `myself` (your own DM); give it positionally or with
`--person`. With `--loop false` (the default) it stops after the first match;
with `--loop true` it keeps running and fires on every match, and you can stop
it by sending `!quit` in the watched conversation. All flags accept
`--flag value` or `--flag=value`. It ignores its own status messages, so in loop
mode pick a `--message` that will not appear in your command's output.

Run commands posted to a channel:

```sh
runitnow '#ops'                            # watch a channel in the background
runitnow @alice                            # or a DM
```

`runitnow` polls the channel once a second in the background. Any message that
starts with `!!` is run as a shell command and the output is posted as a
threaded reply to that message, led by which instance answered and the output in
a code block. For example, posting `!!echo "HI"` replies:

````
<pid> running on machine <host> replies:
```
HI
```
````

If the output is too large to inline, the reply shows the head and the full
output is attached as a file in the thread.
It returns immediately and prints a pid. Several control words help when more
than one watcher (e.g. on different machines) is on the same channel; a
*target* is a watcher's pid or its hostname:

- `!!report` — every watcher replies in-thread with its pid, host, and channel.
- `!!quit` / `!!stop` — every watcher of the channel stops.
- `!!quit <target>` / `!!stop <target>` — only watchers matching the target
  (a pid, or a hostname to stop all of that host's watchers) stop.
- `!!@<target> <command>` — only watchers matching the target run the command;
  the others ignore it. A bare `!!command` still runs on every watcher.

You can also stop one from the shell with `kill <pid>`. Only messages posted
after it starts are run. To survive logout, run it under `nohup`, `disown`, or
inside `tmux`.

Commands run in a non-interactive shell that sources `~/.bashrc` first (with
alias expansion enabled), so your functions and aliases work too. For example,
posting `!!nup mg1-systel` runs the `nup` alias.

WARNING: `runitnow` executes arbitrary commands from anyone who can post to the
watched channel, as you. Only point it at a channel you trust.

`notify_up` returns immediately and runs in the background of your shell. To
survive logout, run it under `nohup`, `disown`, or inside `tmux`.

## Refreshing

The session expires whenever Slack makes you log in again in the browser. When
a command returns `invalid_auth` or `not_authed`, log back into Slack in Firefox
and run `slack-refresh`. It validates the credentials before overwriting the
file, so a bad read never breaks a working session.

You cannot automate the login itself. `slack-refresh` only copies whatever the
live browser session currently holds.

## Security and policy

- `~/.slack_session` holds your live Slack session. Treat it as a password. It
  is written with `chmod 600`.
- This grants the same access your Slack account has, including posting as you.
- Using a personal session for automation may violate your organization's
  policy. If your workspace disabled bot creation on purpose, check before you
  rely on this. The sanctioned alternative is a service account or bot token
  from your Slack admins.

## Uninstall

```sh
./uninstall.sh
```

This removes the installed files and the rc source block. It leaves
`~/.slack_session` in place. Delete it yourself if you want the credentials gone.
