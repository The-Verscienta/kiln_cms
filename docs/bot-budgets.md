# Bot budgets

Public pages are rate-limited per address: a browser may make 300 requests a
minute from one address before it is refused (the `:delivery` limit). Since
#2243 a request that says it is something other than a browser (a search
engine, an AI crawler, a script, or nothing at all) is refused at its own share
of that limit. By default scripts get half and clients with no user agent a
fifth; AI crawlers keep the full limit, and search engines whose address DNS
has verified get twice it. A site admin can
lower those shares for their site; the operator sets the most any site may have.

**This is cost control, not security.** The class comes from the `User-Agent`
header, which is whatever the client typed. Anyone can claim to be a browser.
A claim to be a search engine is checked against DNS since #2254, and a claim
proven false is charged as no user agent (see
[Verified search engines](#verified-search-engines)), but every other class is
taken on trust. A budget limits how much a well-behaved crawler or a careless
script costs you; it does not keep anyone out. To keep a crawler out, see
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

A request put in **Search engine** is then checked against DNS before it is
charged, and charged as **No user agent** if the address is proven not to be
the engine's. See [Verified search engines](#verified-search-engines).

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
| Search engine | 200% | 600 if DNS has verified the address, otherwise at most 300 |
| AI crawler | 100% | 300 |
| Other bot | 50% | 150 |
| No user agent | 20% | 60 |

A real search engine crawls a site in bursts, often from a few addresses, and
an indexing backlog costs the site more than the extra requests do. So since
#2587 a search engine gets twice what a browser gets, but only from an address
DNS has proven to be the engine's (see
[Verified search engines](#verified-search-engines)). Typing "Googlebot" earns
nothing: a claim not yet checked, or one DNS could not answer, is held to the
browser limit, and a claim proven false gets the **No user agent** ceiling. With
verification off, nothing is proven, so the search-engine default is 100%
instead. AI crawlers keep exactly what they had before classes existed, and
browsers are throttled exactly as before.

The extra 300 a minute is per verified address and, like every ceiling here,
per node. Only the engines' own addresses can spend it, and only by crawling
the site's public pages. To keep the browser limit, set
`KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=100` (see
[Set the deployment values](#set-the-deployment-values)), or lower it for one
site on the **Bot budgets** page.

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
   see who is in the class, the value in force, what it comes to, and where it
   comes from, for example "50% - 150 requests a minute per address (Default)",
   then "The server allows at most 50% here." Under **Search engines (%)** the
   page says the class holds those crawlers "when the address checks out as
   theirs", and under **No user agent (%)** that it also holds "claimed search
   engines proven not to be them". The **How claims are checked** link under
   **Search engines (%)** opens [Verified search engines](#verified-search-engines).
   While the search-engine figure is above 100% (it is by default), the page also
   says "Above 100%, this applies only to addresses verified as the search engine
   they name. Any other claim gets at most 300 requests a minute per address,
   like a browser." If the operator has turned verification off,
   **Search engines (%)** instead says "This server does not check search-engine
   claims, so any client naming one gets this budget." and "The server operator
   can turn checking on with KILN_CRAWLER_VERIFICATION."
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
| `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT` | Search engine | `200` (`100` with `KILN_CRAWLER_VERIFICATION=false`) |
| `KILN_BOT_BUDGET_AI_CRAWLER_PERCENT` | AI crawler | `100` |
| `KILN_BOT_BUDGET_DECLARED_BOT_PERCENT` | Other bot | `50` |
| `KILN_BOT_BUDGET_EMPTY_UA_PERCENT` | No user agent | `20` |

Each must be a whole number from 1 to 1000. Anything else (`0`, `abc`, `2.5`,
`5000`) keeps the default and warns at boot. They are read in every environment
except `:test`, at boot, so a change needs a restart.

For example, to let search engines spend four times the browser limit and give
clients with no user agent only 10%:

```sh
KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=400
KILN_BOT_BUDGET_EMPTY_UA_PERCENT=10
```

With the shipped limit, that is 1200 and 30 requests a minute per address. Other
bots and AI crawlers keep their defaults. The 1200 goes only to addresses DNS
has verified as the search engine they claim: a claim not yet checked, or one
DNS could not answer, is held to 300, and one proven false gets the No user
agent ceiling, 30 here.

To give search engines no more than browsers, as before #2587, set
`KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=100`.

With `KILN_CRAWLER_VERIFICATION=false`, an unset search-engine variable means
100%, so an unchecked claim never gets more than a browser. A value you set is
used as given: 400% is then 400% for anyone who claims to be a search engine.

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

## Verified search engines

A user agent is easy to fake, so since #2254 Kiln checks a claim to be a search
engine against DNS before it trusts it with that class's ceiling
(`KilnCMS.CrawlerVerification`). The check is the one each engine documents:

1. Look up the address's PTR (reverse DNS) name.
2. The name must be the engine's domain or end in `.` and that domain.
3. Look the name up forward (an A record for an IPv4 client, AAAA for IPv6).
   The answer must contain the address the request came from.

Step 3 is the proof: anyone who controls an address's reverse zone can make its
PTR name say `googlebot.com`, but only Google can make `googlebot.com` names
resolve to that address.

| Engine (user agent) | The PTR name must end in | Engine's own instructions |
|---|---|---|
| Google (`Googlebot`, `Google-InspectionTool`) | `googlebot.com` | [Verify requests from Google crawlers](https://developers.google.com/crawling/docs/crawlers-fetchers/verify-google-requests) |
| Bing (`bingbot`) | `search.msn.com` | [How to verify that Bingbot is Bingbot](https://blogs.bing.com/webmaster/2012/8/How-to-Verify-that-Bingbot-is-Bingbot/) |
| Apple (`Applebot`) | `applebot.apple.com` | [About Applebot](https://support.apple.com/en-us/119829) |
| Yandex (`YandexBot`) | `yandex.ru`, `yandex.net` or `yandex.com` | [How to check that a robot belongs to Yandex](https://yandex.com/support/webmaster/en/robot-workings/check-yandex-robots.html) |
| Baidu (`Baiduspider`) | `baidu.com` or `baidu.jp` | [Baiduspider help](https://help.baidu.com/question?prod_id=99&class=0&id=3001) |
| DuckDuckGo (`DuckDuckBot`) | cannot be checked: DuckDuckGo publishes IP addresses only | [DuckDuckBot](https://duckduckgo.com/duckduckgo-help-pages/results/duckduckbot) |

Google also lists `google.com` and `googleusercontent.com` names, but those are
its special-case crawlers and user-triggered fetchers, not the crawlers above,
and `googleusercontent.com` is the reverse DNS of any Google Cloud customer.
Kiln does not accept them. So `evilgooglebot.com`, `googlebot.com.example.net`
and `crawl.googleusercontent.com` all fail for Google.

### What a request is charged as

Only the search-engine class is checked; a browser, an AI crawler or a script
never triggers a lookup.

| What DNS says about the claim | Charged as | Ceiling with the defaults |
|---|---|---|
| **Verified**: the name is under the engine's domain and resolves back to the address | Search engine | 600 a minute |
| **Proven false**: no PTR record, a PTR name outside the engine's domain, or a name that does not resolve back to the address | No user agent | 60 a minute |
| **Not proven either way**: the lookup has only just started, could not start (the node is busy, the network used its lookup budget, the verifier is restarting), timed out or got a DNS error; the engine is DuckDuckBot; or the address is private, a `TRUSTED_PROXIES` address, or arrived through a forwarding header nothing trusts | Search engine, but never above the browser limit | 300 a minute |
| Verification is off (`KILN_CRAWLER_VERIFICATION=false`) | Search engine | 300 a minute (the default is 100% while verification is off) |

So only a verified address gets more than a browser, whatever the
search-engine percentage. A site's lower value applies in every row.

**A request never waits for DNS.** The first request from a new address is
judged as "not proven" while a lookup starts in the background, and later
requests from that address are judged by its result.

**Results are cached per node, per address.** A verified address is trusted for
6 hours, a proven false one is held for 1 hour, and a DNS error is retried after
5 minutes. Nothing is cached when no lookup was made. Each node keeps its own
cache, so a new node checks an address again.

**Each lookup is bounded.** At most three DNS queries per address: one PTR query,
then a forward query for at most two of the first three PTR names. The whole
lookup has a 3-second deadline. A node runs at most 16 lookups at a time and
queues none: a claim that arrives while 16 are running is left unchecked, and a
later request tries again. New lookups are also rate limited per network, so
one party cannot buy a lookup for every address it holds:

| Network | New lookups a minute |
|---|---|
| IPv4 `/24` | 30 |
| IPv4 `/16` | 120 |
| IPv6 `/64` | 30 |
| IPv6 `/48` | 60 |
| IPv6 `/32` | 120 |
| The whole node | 600 |

None of these limits has an environment variable.

### Check that a node can verify crawlers

You need shell access to a running node. Verification is on by default, so
these steps confirm it can work where you deploy.

1. **Let the node send DNS queries.** Lookups go to the nameservers in the
   node's `/etc/resolv.conf` (inside a container, the container's), as PTR, A
   and AAAA queries. A firewall or network policy that allows only HTTPS out
   blocks them.
2. **Behind a reverse proxy or a load balancer, set `TRUSTED_PROXIES`** (or, on
   Fly.io, Railway or DigitalOcean App Platform, `CLIENT_IP_HEADER`); see
   [Environment variables](environment-variables.md#server-and-networking).
   Without it every request seems to come from the proxy, which is not a
   crawler's address, so no claim can be checked. Claims then stay "not
   proven": they keep the search-engine ceiling up to the browser limit, but a
   value above 100% never applies.
3. **Ask the node to check a known Googlebot address.** On a release:

   ```sh
   bin/kiln_cms rpc 'IO.inspect(KilnCMS.CrawlerVerification.verify(:google, {66, 249, 66, 1}))'
   ```

   You should see the name Google publishes for that address:

   ```
   {:verified, "crawl-66-249-66-1.googlebot.com"}
   ```

   The same address claimed as Bing prints `{:rejected, :wrong_domain}`.
   `verify/3` asks DNS directly and waits for it (up to 3 seconds); it skips the
   cache and the limits above, and its answer is not saved.
4. **Watch the lookups.** With metrics on,
   `kiln_cms_crawler_verification_lookup_count{engine, result}` counts finished
   lookups. A real crawler's lookups end `result="verified"`; a steady
   `timeout` or `error` share means the node cannot reach DNS. See
   [Observability](observability.md#crawler-verification).

### What can go wrong

| What you see | What it means |
|---|---|
| `{:error, :timeout}` from step 3 | No DNS answer within 3 seconds: the node cannot reach its resolver, or the resolver cannot reach the internet. Open DNS egress, or turn verification off. |
| `{:error, :servfail}`, `{:error, :refused}` or another `{:error, _}` from step 3 | The resolver answered with an error. Same remedies. |
| `{:rejected, :no_ptr}` for an address you know is the crawler's | That address has no PTR record from your resolver's point of view. Check the address against the engine's own instructions above. |
| Log warning "Crawler verification: 20 DNS lookups in a row timed out or failed; check that this node can reach its DNS resolver, or set KILN_CRAWLER_VERIFICATION=false to turn verification off" | Logged once per node. Every claim is being judged "not proven", which keeps the search-engine ceiling up to the browser limit, so crawlers are not refused because of it. |
| Log warning "Crawler verification is at its concurrent-lookup limit; new search-engine claims go unchecked until a lookup finishes" | Logged once per node, the first time 16 lookups were already running. Unchecked claims are "not proven". Occasional is normal; a steady `kiln_cms_crawler_verification_skipped_count{reason="busy"}` means slow DNS. |
| `kiln_cms_delivery_unverified_crawler_count{reason="not_public"}` for most claims | The node sees a proxy's address, not the client's. Set `TRUSTED_PROXIES` (step 2). |

### Turn verification off

If a node cannot reach DNS and you would rather not have it try, set:

```sh
KILN_CRAWLER_VERIFICATION=false
```

and restart. Every search-engine claim is then believed for rate limiting, as
before #2254, and the console's **Bot budgets** page says so under **Search
engines (%)**. Because no claim is proven, the search-engine default drops from
200% to 100%, the browser limit; a `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT` you
set still applies, to every claim. The smart 404 guard also goes back to exempting the six search
engines by name (see [Block scanners automatically](ip-blocking.md#block-scanners-automatically)).
The variable is read at boot in every environment except `:test`; there is no
per-site switch.

## Watching the traffic mix

Every `:delivery` request emits `[:kiln_cms, :delivery, :client_class]` with its
`class` and `result` (`allowed` or `throttled`), and nothing else: no user agent,
address or site. `class` is the class the request was **charged** as, so a
search-engine claim proven false by DNS counts as `empty`. It is exported as the
counter `kiln_cms_delivery_client_class_count{class, result}` when metrics are
on (see [Observability](observability.md#delivery-client-classes)). A useful
panel:

```
sum(rate(kiln_cms_delivery_client_class_count[5m])) by (class, result)
```

To see how many search-engine claims were not verified, and why, use the
counter `kiln_cms_delivery_unverified_crawler_count{engine, reason}` (see
[Observability](observability.md#crawler-verification)):

```
sum(rate(kiln_cms_delivery_unverified_crawler_count[5m])) by (engine, reason)
```

Its `reason="failed"` series is the share of `class="empty"` that claimed to be
a search engine.

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
- **Search-engine claims are checked against DNS (#2254), on by default.** Each
  node now sends PTR, A and AAAA queries to its own resolver for addresses whose
  user agent names a search engine. Allow that egress, set `TRUSTED_PROXIES`
  behind a proxy, and confirm with
  [Check that a node can verify crawlers](#check-that-a-node-can-verify-crawlers).
  A claim proven false drops to 60 requests a minute; real crawlers and
  unchecked claims keep 300. No migration; rolling the pin back is safe and
  goes back to believing every claim.
- **Verified search engines get twice the browser limit by default (#2587).**
  An address DNS has verified as Googlebot, Google-InspectionTool, bingbot,
  Applebot, YandexBot or Baiduspider may make 600 requests a minute instead of 300; nothing else
  changes. Behind a proxy without `TRUSTED_PROXIES` no address is verified, so
  nothing changes there either. To keep 300, set
  `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=100` and restart. Rolling the pin back
  goes back to 300.

## What this is not

- **Not access control.** Every class but the search-engine one is reachable by
  typing its user agent, and a search-engine claim keeps its ceiling (up to the
  browser limit) until DNS proves it false. Verification only decides how much
  an address may spend; it never lets anyone in.
- **Not verification by IP range.** DuckDuckBot publishes only IP addresses, so
  it is never verified, and the published ranges of the other engines are not
  read either. A DuckDuckBot claim keeps the search-engine ceiling, up to the
  browser limit.
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
