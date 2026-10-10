# Deployment presets

Three environment files that turn Kiln's runtime features on or off as a
set. Each is a layer **on top of** `.env.prod`, which still carries the
three required variables (`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`) and
your secrets; a preset holds no secret and no hostname.

```bash
docker compose -f docker-compose.prod.yml \
  --env-file .env.prod --env-file deploy/presets/publishing.env up -d
```

Later `--env-file` flags win, so the preset overrides `.env.prod` where both
set a variable (Compose 2.24+). On a platform without env files (Coolify,
Render, Fly), paste the preset's uncommented lines into its environment
settings.

| Preset | Image | What is on | Extra services |
|---|---|---|---|
| `minimal.env` | `kiln_cms:1.x` | The console, delivery, backups, media on a volume. No mail leaves the box. | Postgres |
| `publishing.env` | `kiln_cms:1.x` | Mail over SMTP, oEmbed cards, provenance signing, CDN purge hooks, error tracking | Postgres, an SMTP relay, optionally S3 and a CDN |
| `everything.env` | `kiln_cms:1.x-ml` | `publishing` plus Meilisearch, federation, experiments, metrics, the LLM assistants and reranking | Postgres, SMTP, S3, Meilisearch, an LLM provider |

Every variable is documented in
[`docs/environment-variables.md`](../../docs/environment-variables.md); the
presets only pick values. The full matrix of what each needs from the host
is in [`docs/system-requirements.md`](../../docs/system-requirements.md).
