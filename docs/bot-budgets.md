# Bot budgets

Public pages are rate-limited per address: a browser may make 300 requests a
minute from one address before it is refused (the `:delivery` limit). Since
#2243 a request that says it is something other than a browser (a search
engine, an AI crawler, a script, or nothing at all) is refused at its own share
of that limit. By default scripts get half and clients with no user agent a
fifth; search engines and AI crawlers keep the full limit. A site admin can
lower those shares for their site; the operator sets the most any site may have.

**This is cost control, not security.** The class comes from the `User-Agent`
header, which is whatever the client typed. Anyone can claim to be Googlebot or
a browser. A budget limits how much a well-behaved crawler or a careless script
costs you; it does not keep anyone out. To keep a crawler out, see
[What this is not](#what-this-is-not).

## How a request is classified

`KilnCMS.BotClass` reads the first 512 bytes of the `User-Agent` header,
case-insensitively, and puts the request in one of five classes. The first rule
that matches decides:

| Order | The user agent | Class |
|---|---|---|
| 1 | names an AI crawler: `GPTBot`, `ChatGPT-User`, `OAI-SearchBot`, `ClaudeBot`, `Claude-User`, `Claude-SearchBot`, `anthropic-ai`, `CCBot`, `PerplexityBot`, `Perplexity-User`, `Bytespider`, `Amazonbot`, `meta-externalagent` | AI crawler |
| 2 | names a search engine: `Googlebot` (and `Googlebot-Image`, `-News`, `-Video`), `Google-InspectionTool`, `bingbot`, `DuckDuckBot`, `Baiduspider`, `YandexBot`, `Applebot` | Search engine |
| 3 | names both an AI crawler and a search engine | Other bot (it gets neither ceiling) |
| 4 | is a scripting tool or headless browser (`curl/`, `Wget/`, `python-requests/`, `Python-urllib/`, `python-httpx/`, `aiohttp/`, `Go-http-client/`, `Java/`, `libwww-perl/`, `Scrapy/`, `axios/`, `node-fetch/`, `PostmanRuntime/`, `Apache-HttpClient/`, `req/`, `HeadlessChrome`, `PhantomJS`), a link-preview fetcher (`facebookexternalhit`, `Twitterbot`, `Slackbot`, `LinkedInBot`, `Discordbot`) or an SEO crawler (`PetalBot`, `AhrefsBot`, `SemrushBot`) | Other bot |
| 5 | looks like a browser: starts `Mozilla/5.0 (` and contains `AppleWebKit/`, `Gecko/` or `Trident/` | Browser |
| 6 | has a product name ending in `bot`, `crawler`, `spider` or `scraper` (`UptimeRobot/2.0`, `MyCrawler;`) | Other bot |
| 7 | is anything else that is not empty | Browser |

A missing, empty or all-whitespace user agent is **No user agent**.

Rule 7 is deliberate. Media players (`AppleCoreMedia`, `stagefright`,
`ExoPlayerLib`, VLC, Roku), the native HTTP stacks of mobile apps (`CFNetwork`,
`Dalvik`, `okhttp`) and old browsers send user agents no list can keep up with,
and they are far more often a person than a scraper. A scraper that wants
browser treatment can claim it anyway.

Which names belong to which class is curated in code, not configured. What you
configure is how much each class may spend. Adding a name is a code change in
`KilnCMS.BotClass` with a test row.

### Which requests are classified

Only requests on the `:delivery` rate limit: public pages, `/search`,
`/membership`, the embeddable form page `/forms/:slug/embed`, `POST /_unlock`,
and media downloads and streams (`/media/:id/download`, `/media/:id/stream`).

Never classified, so never charged by class:

- `/robots.txt`, `/llms.txt`, `/sitemap.xml`, `/news-sitemap.xml`, every feed and
  calendar, `security.txt` and `/up` / `/ready`. These are on the `:probe` limit
  (600 a minute per address).
- `/live`, the liveness probe, which is answered before any rate limit.
- The APIs (`/api/*`, `/gql`, `/mcp`), which have their own limits, and image
  transforms (`/media/:id/t/…`).
- Static assets and `/uploads/*`.

Point load-balancer and uptime checks at `/up`, not at a page: a page check sent
by `curl` counts as another bot.

## How the ceilings work

Each class's ceiling is a percentage of the `:delivery` limit:

```
ceiling = max(1, div(delivery_limit * percent, 100))
```

With the shipped limit of 300 a minute, the built-in defaults give:

| Class | Default | Requests a minute per address |
|---|---|---|
| Browser | 100% (always) | 300 |
| Search engine | 100% | 300 |
| AI crawler | 100% | 300 |
| Other bot | 50% | 150 |
| No user agent | 20% | 60 |

Search engines and AI crawlers keep exactly what they had before classes
existed. Because the user agent can be spoofed, a higher default would raise the
flood ceiling for anyone who types "Googlebot". Browsers are throttled exactly
as before.

**All classes share one counter per address.** A request is counted once, and
refused if the count is past its own class's ceiling. So switching user agents
earns nothing: an address can never get past the highest single ceiling. The
flip side is that browsers and scripts behind one address (an office NAT, a
CI runner) spend the same count. Once that office's browsers have made 150
requests in a minute, a `curl` uptime check from the same office is refused
until the window resets.

The window is the `:delivery` window, one minute, aligned to the clock. Like
every flood ceiling, it is counted per node, so behind a load balancer with
three nodes one address can make up to three times the ceiling.

A refused request gets the same `429 Too Many Requests` as before, with a
`Retry-After` header. Browsers (`Accept: text/html`) get the small "Too many
requests" page; other clients get the JSON error. The response never says
which class it was put in.

## Lower the budgets for one site

You need the admin role. An editor does not see the page.

1. Open **Bot budgets** under **Sign-in & access** in the console sidebar, next to
   **Blocked addresses**, or go to `/editor/bot-budgets`. The page starts with
   the browser line, for example
   "**Browsers** - 300 requests a minute per address. This is the delivery limit,
   set by the server."
2. Find the class to change: **Search engines (%)**, **AI crawlers (%)**,
   **Other bots and scripts (%)** or **No user agent (%)**. Under each field you
   see the value in force, what it comes to, and where it comes from, for
   example "50% - 150 requests a minute per address (Default)", then
   "The server allows at most 50% here."
3. Type a whole-number percentage, lower than or equal to the server's value.
   Leave a field blank to use the server's value for that class.
4. Select **Save**. You see "Bot budgets saved." and the line under the field
   now ends "(Set for this site)".

The change applies to the next request, on every node.

For example, to give scripts a third of the browser limit and requests with no
user agent a tenth, type `33` in **Other bots and scripts (%)** and `10` in
**No user agent (%)**, and save. With the 300 a minute limit the lines read
"33% - 99 requests a minute per address (Set for this site)" and
"10% - 30 requests a minute per address (Set for this site)". Search engines
and AI crawlers keep the server's values.

If **Search engines (%)** is below 100, the page shows "Search engines will be
refused sooner than browsers. That can slow how quickly new pages are indexed."
That is a warning, not a refusal.

To go back to the server's values for every class, select **Use the server's
values** (shown once the site has saved anything) and confirm "Go back to the
server's values for this site?". You see "Bot budgets reset to the server's
values."

Every save and reset is recorded in the [security log](security-events.md) as
"Site setting changed", naming the setting, not the values.

### What can go wrong

| What you see | What it means |
|---|---|
| Enter a whole number from 1 to 1000, or leave it blank. | The field holds something other than a whole number from 1 to 1000. There is no 0 and no "unlimited". |
| At most 50%: this server's operator caps it there. | A site may only lower a class. The number is the operator's value for that class. Ask the operator to raise it, or choose a lower value. |
| Your browser's own "value must be less than or equal to" message | The field's maximum is the server's value, so the browser may stop the form before it is sent. Same meaning as the row above. |
| This site asks for 80%, above what the server now allows. | The site saved a value, and the operator has since lowered theirs below it. The operator's value is in force; the stored value is kept and can still be saved unchanged with the other fields. Type a lower value, or clear the field, to tidy it. |
| You don't have permission to change this site's bot budgets. | You are not an admin of this site, or lost the role since the page opened. |
| The bot budgets could not be saved. | Anything else went wrong saving; try again. |

## Set the deployment values

The operator sets the percentage each class gets, with one environment variable
per class. Each replaces the built-in default and is the most any site may set.

| Variable | Class | Default |
|---|---|---|
| `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT` | Search engine | `100` |
| `KILN_BOT_BUDGET_AI_CRAWLER_PERCENT` | AI crawler | `100` |
| `KILN_BOT_BUDGET_DECLARED_BOT_PERCENT` | Other bot | `50` |
| `KILN_BOT_BUDGET_EMPTY_UA_PERCENT` | No user agent | `20` |

Each must be a whole number from 1 to 1000. Anything else (`0`, `abc`, `2.5`,
`5000`) keeps the default and warns at boot. They are read in every environment
except `:test`, at boot, so a change needs a restart.

For example, to let search engines spend twice the browser limit and give clients
with no user agent only 10%:

```sh
KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=200
KILN_BOT_BUDGET_EMPTY_UA_PERCENT=10
```

With the shipped limit, that is 600 and 30 requests a minute per address. Other
bots and AI crawlers keep their defaults. Remember that 200% for search engines
is 200% for anyone who claims to be one.

**Precedence.** The built-in default, then the operator's variable, then the
site's value, which can only lower it: the value in force is
`min(site, operator)`. A site write above the operator's value is refused
(`KilnCMS.CMS.Validations.BotBudgetCeiling`), and a stored value above it is
clamped when it is read, so lowering a variable takes effect on every site at
the next restart. Each class is separate: a site that sets one class keeps the
operator's values for the others. Why the site may not raise a value is recorded
in [ADR 0018](decisions/0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md).

The browser ceiling is the `:delivery` limit itself and has no variable. It
comes from `KilnCMSWeb.RateLimit`, and raising it raises every class with it.

### Benchmarks

A benchmark that raises `:delivery` raises every class in proportion, which is
usually what you want. But setting the whole `KilnCMSWeb.RateLimit` config with
`Application.put_env/3`, as [performance.md](performance.md#running-a-basic-load-check)
shows, replaces the `delivery_classes` key the variables above write, so the
built-in defaults apply for the rest of that node's life. Load tools mostly
count as browsers (`hey`, `oha`, `k6`, `ab`); `curl` counts as another bot.

## How fast a change takes effect

A site's saved values are cached per site for five minutes. A save or reset in
the console clears that cache on every node at once. A row changed directly in
the database is seen within five minutes.

Browser requests never look the site's values up. Other classes are checked
against the operator's ceiling first, with no database read; only a request that
passes it reads the site's (cached) values.

If the site's values cannot be read (database trouble, a missing table during a
deploy), the request is checked against the operator's values, which are never
looser than what the operator allowed, and a warning is logged. That answer is
reused for 20 seconds, so an outage costs one read per site every 20 seconds
rather than one per request.

## Watching the traffic mix

Every `:delivery` request emits `[:kiln_cms, :delivery, :client_class]` with its
`class` and `result` (`allowed` or `throttled`), and nothing else: no user agent,
address or site. It is exported as the counter
`kiln_cms_delivery_client_class_count{class, result}` when metrics are on (see
[Observability](observability.md#delivery-client-classes)). A useful panel:

```
sum(rate(kiln_cms_delivery_client_class_count[5m])) by (class, result)
```

## Upgrading

- **Run `mix ash.migrate`.** The release adds one table, `site_bot_budgets`, one
  row per site, created when an admin first saves. Nothing existing changes.
  Rolling the pin back is safe: the previous release ignores the table, and
  every client goes back to 300 a minute.
- **Scripts and clients with no user agent get less.** On every `:delivery`
  route, `curl`, `wget`, Go, Java and Python clients (and anything else in the
  "Other bot" rows above) drop from 300 to 150 requests a minute per address, and
  requests with no user agent drop to 60. That includes `/media/:id/download`
  and `/media/:id/stream`. A headless consumer of those should send a user agent
  of its own (one that names neither a tool nor a bot), or the operator can raise
  the class.
- **Shared addresses share the count.** Check uptime checks and scripts that
  fetch pages from an office or a CI runner; see
  [How the ceilings work](#how-the-ceilings-work).

## What this is not

- **Not access control.** Every class is reachable by typing its user agent. A
  verified-crawler check by reverse DNS is
  [#2254](https://github.com/The-Verscienta/kiln_cms/issues/2254), and higher
  defaults for verified crawlers belong there.
- **Not a way to block a crawler.** No value is 0. To refuse an address or range,
  use [Blocked addresses](ip-blocking.md). To ask a crawler to stay away, use
  `robots.txt`; note that Kiln's generated `/robots.txt` allows every crawler and
  has no console setting, so a site that needs `Disallow` rules serves its own
  from a CDN or reverse proxy in front of Kiln.
- **`Google-Extended` and `Applebot-Extended` never arrive.** They are
  robots.txt product tokens only: Google and Apple crawl with their ordinary user
  agents and read those tokens to decide how the content may be used. There is
  nothing to classify.
- **Not complete.** Some crawlers that send a browser-shaped user agent without a
  listed name count as browsers (for example `GoogleOther` and `AdsBot-Google`),
  and some search engines not on the list count as other bots (for example
  `SeznamBot` and `Qwantbot`).
- **Not in the API.** The settings are not on JSON:API, GraphQL or MCP. Only a
  site admin, in the console, and the delivery limiter (as a read-only system
  actor, see the [policy matrix](policy-matrix.md)) can read them.

See also the [threat model](threat-model.md#bot-budgets) and
[Blocked addresses](ip-blocking.md).
