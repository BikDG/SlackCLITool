# slack-session-cli

Send Slack messages from your terminal without a Slack app or bot token.

It authenticates as your own Slack browser session, reusing the `xoxc` token and
`d` cookie that Firefox already holds after you log in. This is useful when your
workspace has disabled app creation and you cannot mint a bot token, but you can
still log into Slack in a browser.

## What you get

- `slack_send` — send a message to yourself, a channel, or a user.
- `slack_upload` — upload a file (with `save_file` and `send_file` as shortcuts).
- `lmk` — run a command, then Slack you its result and full output.
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

notify_up build-server                     # DM yourself when the host pings
notify_up build-server -c '#builds'        # message a channel instead
nup build-server                           # same, short alias
```

Files and command output:

```sh
save_file report.pdf                       # upload a file to your own DM
send_file report.pdf -c '#team'            # upload to a channel
slack_upload -c @alice -m 'see this' x.log # upload with a comment

lmk make                                   # run `make`, then DM you pass/fail
lmk -c '#builds' ./deploy.sh               # report the result to a channel
```

`lmk` streams the command's output to your terminal as usual, then sends a
pass/fail summary with the last 25 lines and attaches the full output as a file.

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
