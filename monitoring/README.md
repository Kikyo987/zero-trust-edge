# Observability

Prometheus + Grafana + Loki, plus node-exporter, cAdvisor, and
Alertmanager. Every published port is `127.0.0.1`. Operators reach
Grafana over Tailscale or Cloudflare Access, not a public `:3000`.

```
monitoring/
  prometheus/{prometheus.yml,alerts.yml}
  alertmanager/{alertmanager.yml,start.sh,secrets/*.example}
  grafana/dashboards/edge-overview.json
  loki/loki.yml
  alloy/config.alloy
```

The processes themselves live in `docker/compose/docker-compose.yml`
(`make dev-up`).

## Alertmanager → Discord / Telegram

```bash
cd monitoring/alertmanager/secrets
cp discord_webhook_url.example discord_webhook_url
cp telegram_bot_token.example telegram_bot_token
cp telegram_chat_id.example telegram_chat_id
# edit the three files; they are gitignored
```

- **Discord:** one webhook URL. Default receiver for every alert.
- **Telegram:** BotFather token + numeric chat id. **Pages**
  (`severity=page`) also go here. If the files are empty, `start.sh`
  drops the Telegram receiver so Alertmanager still starts.

Do not put the webhook in `alertmanager.yml`. That file is committed.

## Prove Grafana is working (60 seconds)

`make dev-up` already provisions `grafana/dashboards/edge-overview.json`
(`uid: edge-overview`). No import click.

1. Open http://127.0.0.1:3000 (admin / password from `.env`).
2. Dashboards → Edge → **Edge overview**.
3. The **scrape health** row should show `UP` for `edge-echo`,
   `prometheus`, `node`, `cadvisor` within ~30s.
4. Hit the app a few times, then the **edge-echo request rate** panel
   moves:

```bash
for i in $(seq 1 20); do curl -sS -o /dev/null http://127.0.0.1:8080/; done
```

If Grafana were published on `0.0.0.0:3000`, `./scripts/zero-trust-verify.sh --compose` would FAIL. The compose file binds `127.0.0.1:3000`.

## Dashboard panels

- scrape health (`up`)
- host CPU / memory (node-exporter)
- container CPU / working set (cAdvisor)
- `edge-echo` request rate
- disk free
- logs from alertmanager / prometheus / the app
