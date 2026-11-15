# openinbox-telegram-notify

Get a Telegram message when a new mail arrives in [OpenInbox](https://github.com/sums001/OpenInbox),
the self-hosted mail service on Cloudflare Workers.

```
📬 me@ · from someone@example.org
Subject: Hello there
Open in OpenInbox
```

- You pick which addresses notify you. The rest stay quiet.
- It only reads the admin mail-flow log (sender, recipient, subject), never the message bodies.
- On the first run it starts from the newest mail, so you don't get a flood of old messages.
- One bash script. It needs only `curl` and `jq`.

## How it works

OpenInbox has no public API keys yet, so the script logs in to the web API with an admin account,
keeps the session cookie, and reads `/api/admin/mailflow` every minute. It remembers the last ID it
has seen and sends one Telegram message for every newly delivered mail to an address in `WATCH`.

## Setup

1. **Telegram bot:** create one with [@BotFather](https://t.me/BotFather), send it a message, then
   look up your chat ID with `https://api.telegram.org/bot<TOKEN>/getUpdates`.
2. **OpenInbox account:** create a separate account with the **Admin** role for the script.
   It does not need to be a member of any mailbox.
3. **Install:**

   ```bash
   install -m 755 openinbox-telegram-notify.sh /usr/local/bin/
   install -m 600 config.example.env /etc/openinbox-telegram-notify.env
   # edit /etc/openinbox-telegram-notify.env
   openinbox-telegram-notify.sh --dry-run   # first run only remembers the newest mail
   install -m 644 systemd/openinbox-telegram-notify.* /etc/systemd/system/
   systemctl daemon-reload && systemctl enable --now openinbox-telegram-notify.timer
   ```

`--dry-run` prints the messages instead of sending them and does not save anything.
Use `OITN_CONFIG=/path/to/file.env` to point to another config file.

## Security

- Keep the config file at `chmod 600`. It holds the admin password and the bot token.
- The password is passed to `curl` through stdin, so it never shows up in the process list.
- The session cookie and the last seen ID live in `STATE_DIR` (`chmod 700`).
- Sender and subject are HTML-escaped before they go to Telegram.

## License

MIT
