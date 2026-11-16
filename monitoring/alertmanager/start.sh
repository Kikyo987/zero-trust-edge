#!/usr/bin/env sh
# Pick Discord and/or Telegram based on which secret files are populated.
# Alertmanager refuses to start if telegram_configs points at an empty token.
set -eu
SRC=/etc/alertmanager/alertmanager.yml
CFG=/tmp/alertmanager.yml
cp "$SRC" "$CFG"

DISCORD=/etc/alertmanager/secrets/discord_webhook_url
TELEGRAM_TOKEN=/etc/alertmanager/secrets/telegram_bot_token
TELEGRAM_CHAT=/etc/alertmanager/secrets/telegram_chat_id

if [ ! -s "$DISCORD" ]; then
  printf '%s\n' 'https://127.0.0.1/disabled-discord-webhook' > /tmp/discord_webhook_url
  sed -i 's|/etc/alertmanager/secrets/discord_webhook_url|/tmp/discord_webhook_url|' "$CFG"
  echo "warn: discord webhook missing; pages will fail open locally" >&2
fi

if [ -s "$TELEGRAM_TOKEN" ] && [ -s "$TELEGRAM_CHAT" ]; then
  CHAT=$(tr -d ' \n' < "$TELEGRAM_CHAT")
  sed -i "s/chat_id: 0/chat_id: ${CHAT}/" "$CFG"
else
  echo "warn: telegram secrets missing; Discord is the only receiver" >&2
  # Drop the telegram route and receiver so AM does not require the token.
  # Busybox sed: delete from the telegram route to the next receiver-less end.
  sed -i '/receiver: telegram/,/continue: true/d' "$CFG"
  sed -i '/name: telegram/,/message:/d' "$CFG"
fi

exec /bin/alertmanager \
  --config.file="$CFG" \
  --storage.path=/alertmanager \
  --web.listen-address=0.0.0.0:9093
