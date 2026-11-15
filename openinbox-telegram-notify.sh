#!/usr/bin/env bash
# openinbox-telegram-notify: sends a Telegram message for every new mail that
# OpenInbox delivers to one of the mailboxes you choose.
#
# It reads only the admin mail-flow log (sender, recipient, subject), never the
# message bodies. Run it every minute, e.g. with the systemd timer in ./systemd.
#
# Usage:  openinbox-telegram-notify.sh [--dry-run]
#   --dry-run   print the messages instead of sending them and do not save state
#
# Config: $OITN_CONFIG (default /etc/openinbox-telegram-notify.env), see config.example.env
set -euo pipefail

CONFIG=${OITN_CONFIG:-/etc/openinbox-telegram-notify.env}
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
done
[[ -r $CONFIG ]] || { echo "config not readable: $CONFIG" >&2; exit 1; }
set -a; . "$CONFIG"; set +a

: "${OPENINBOX_URL:?missing in config}" "${OPENINBOX_EMAIL:?missing in config}" "${OPENINBOX_PASSWORD:?missing in config}"
: "${TELEGRAM_BOT_TOKEN:?missing in config}" "${TELEGRAM_CHAT_ID:?missing in config}" "${WATCH:?missing in config}"
OPENINBOX_URL=${OPENINBOX_URL%/}
MAIL_LINK=${MAIL_LINK:-$OPENINBOX_URL/mail}
STATE_DIR=${STATE_DIR:-/var/lib/openinbox-telegram-notify}
STATE="$STATE_DIR/last-id"
JAR="$STATE_DIR/cookies"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$JAR"; chmod 600 "$JAR"

# Call the OpenInbox web API with the stored session cookie and CSRF token.
api() {
  local method=$1 path=$2 csrf
  csrf=$(awk '$6=="oi_csrf"{print $7}' "$JAR" | tail -1)
  curl -s --max-time 20 -b "$JAR" -c "$JAR" -X "$method" "$OPENINBOX_URL$path" \
    -H "Origin: $OPENINBOX_URL" -H "Content-Type: application/json" -H "X-CSRF-Token: $csrf" "${@:3}"
}

# Log in and store a fresh session. The password goes through stdin, never the command line.
login() {
  api GET /api/auth/session >/dev/null
  jq -nc --arg e "$OPENINBOX_EMAIL" --arg p "$OPENINBOX_PASSWORD" '{email:$e,password:$p}' \
    | api POST /api/auth/login --data-binary @- >/dev/null
}

is_list() { jq -e 'type=="array"' >/dev/null 2>&1 <<<"$1"; }

FLOW=$(api GET /api/admin/mailflow || true)
if ! is_list "$FLOW"; then
  login
  FLOW=$(api GET /api/admin/mailflow || true)
  is_list "$FLOW" || { echo "mail flow unavailable (check URL, account and admin role)" >&2; exit 1; }
fi

MAX=$(jq '[.[].id] | max // 0' <<<"$FLOW")
if [[ ! -s $STATE ]]; then
  # First run: remember where we are instead of flooding the chat with old mail.
  (( DRY_RUN )) || echo "$MAX" > "$STATE"
  echo "first run, starting after mail flow id $MAX"
  exit 0
fi
LAST=$(cat "$STATE")

send() {
  if (( DRY_RUN )); then printf '%s\n---\n' "$1"; return; fi
  curl -sf -o /dev/null --max-time 15 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1" \
    -d parse_mode=HTML -d disable_web_page_preview=true || echo "telegram send failed" >&2
}

# New, delivered mails to a watched address. "+tag" addresses count as the base address.
jq -c --argjson last "$LAST" --arg watch "$WATCH" '
  ($watch | ascii_downcase | split(" ") | map(select(. != ""))) as $w
  | [.[] | select(.id > $last and .status == "delivered")
         | (.to | ascii_downcase | sub("\\+[^@]*@"; "@")) as $to
         | select($w | index($to))
         | . + {box: $to}]
  | sort_by(.id) | .[]' <<<"$FLOW" |
while read -r mail; do
  TEXT=$(jq -r --arg link "$MAIL_LINK" '
    "📬 <b>\(.box | split("@")[0] | @html)@</b> · from <code>\(.from | @html)</code>\n"
    + "Subject: \((.subject // "(no subject)") | @html)\n"
    + "<a href=\"\($link | @html)\">Open mail</a>"' <<<"$mail")
  send "$TEXT"
done

if (( ! DRY_RUN && MAX > LAST )); then echo "$MAX" > "$STATE"; fi
exit 0
