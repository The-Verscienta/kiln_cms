# Bot budgets

Public pages are rate-limited per address: a browser may make 300 requests a
minute from one address before it is refused (the `:delivery` limit). Since
#2243 a request that says it is something other than a browser (a search
engine, an AI crawler, a script, or nothing at all) is refused at its own share
of that limit. By default scripts get half and clients with no user agent a
fifth; AI crawlers keep the full limit, and search engines whose address has
been verified (by DNS, or by the engine's own published list of addresses) get
twice it. A site admin can
lower those shares for their site; the operator sets the most any site may have.

**This is cost control, not security.** The class comes from the `User-Agent`
header, which is whatever the client typed. Anyone can claim to be a browser.
A claim to be a search engine is checked against DNS since #2254, and against
the engine's published IP ranges since #2586, and a claim
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

A request put in **Search engine** is then checked against the engine's
published IP ranges and DNS before it is charged, and charged as **No user agent** if the address is proven not to be
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
engine before it trusts it with that class's ceiling
(`KilnCMS.CrawlerVerification`). The check sends the client's address to the
node's DNS resolver; [ADR 0058](decisions/0058-crawler-verification-sends-a-visitors-address-to-the-dns-resolver-by-default.md) records why that is on by default. Since #2586 the first check is the engine's
own published list of its crawlers' addresses, where it has one (see
[Published IP ranges](#published-ip-ranges)): an address inside a fresh list is
verified at once, with no DNS query. Every other claim gets the DNS check each
engine documents:

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
| DuckDuckGo (`DuckDuckBot`) | no DNS check: DuckDuckGo publishes IP addresses only, and its claims are checked against that list | [DuckDuckBot](https://duckduckgo.com/duckduckgo-help-pages/results/duckduckbot) |

Google also lists `google.com` and `googleusercontent.com` names, but those are
its special-case crawlers and user-triggered fetchers, not the crawlers above,
and `googleusercontent.com` is the reverse DNS of any Google Cloud customer.
Kiln does not accept them. So `evilgooglebot.com`, `googlebot.com.example.net`
and `crawl.googleusercontent.com` all fail for Google.

### Published IP ranges

Google, Bing, Apple and DuckDuckGo each publish a JSON list of the addresses
their crawlers use. Kiln fetches the four lists and checks a claim against the
claimed engine's list before it asks DNS (#2586,
`KilnCMS.CrawlerVerification.Ranges`). Yandex and Baidu publish no list and
are checked by DNS only.

| Engine | List Kiln fetches |
|---|---|
| Google | `https://developers.google.com/static/crawling/ipranges/common-crawlers.json` |
| Bing | `https://www.bing.com/toolbox/bingbot.json` |
| Apple | `https://search.developer.apple.com/applebot.json` |
| DuckDuckGo | `https://duckduckgo.com/duckduckbot.json` |

What a list decides:

- **An address inside the claimed engine's fresh list is verified**, with no
  DNS query, no lookup charged against the limits below and nothing cached.
- **An address outside it is checked by DNS as before**, for Google, Bing and
  Apple. A list that lags behind the vendor therefore never turns a real
  Googlebot into a failure.
- **A DuckDuckBot claim from an address outside DuckDuckGo's fresh list is
  proven false**, because there is no DNS check to fall back on. It is charged
  as no user agent, and with the smart 404 guard on it counts toward the miss
  threshold. DuckDuckGo publishes IPv4 addresses only, so a DuckDuckBot claim
  over IPv6 is never proven false: it stays "not proven".
- **A missing or stale list decides nothing.** A list is fresh for 24 hours
  after it was fetched. A stale or missing list never verifies an address and
  never proves a claim false: Google, Bing and Apple fall back to DNS, and
  DuckDuckBot stays "not proven", as before #2586.

Why a list decides this much and no more: [ADR 0055](decisions/0055-a-fresh-published-list-proves-a-duckduckbot-claim-false-on-its-own-and-a-stale-one-decides-nothing.md).

**When the lists are fetched.** One node in the cluster fetches all four every
6 hours (an Oban cron job, `17 */6 * * *`, `KILN_CRAWLER_RANGES_CRON`), and
sends each list it accepted to the other nodes over Phoenix PubSub. A node
that still has no fresh list 20 seconds after it starts queues a fetch of the
missing ones, and so does a node whose check every 10 minutes finds a list
stale. However many nodes ask, at most one fetch job runs per 10 minutes
across the cluster. A node that starts or reconnects also asks its peers for
the lists they hold. Each list is a few kilobytes to a few tens of kilobytes.
Why one node fetches and the others check what it sends again:
[ADR 0057](decisions/0057-one-node-fetches-the-crawler-ip-lists-and-the-others-re-check-what-it-sends.md).

**This is the first call a default install makes on a schedule.** Every other
default outbound call happens because someone did something (opened a page,
set a password, sent a request). Each fetch is an unauthenticated HTTPS `GET`
of the fixed URL above, through `KilnCMS.SafeFetch`, with a bare `KilnCMS`
user agent, no redirect followed and at most 512 KB read. It carries nothing
about the instance or its visitors; each vendor sees the fetching node's IP
address. Allow it out of your firewall, or turn it off (see
[Turn the published lists off](#turn-the-published-lists-off)). Why a
schedule is allowed for this call by default: [ADR 0056](decisions/0056-the-crawler-ip-lists-are-fetched-on-a-schedule-by-default-because-the-fetch-discloses-nothing.md).

**What makes Kiln refuse a list.** A list is a claim that every address in it
is the vendor's crawler, so a list that would verify too much is refused
whole, never trimmed, and the list held before is kept with its old age. Kiln
refuses a list that:

- is not JSON, or not the `{"prefixes": [{"ipv4Prefix": …}, {"ipv6Prefix": …}]}`
  shape the four vendors publish (a top-level list of strings is read too);
- has no usable range, or more than 5,000 entries;
- holds a range wider than an IPv4 `/20` or an IPv6 `/48`, or ranges that
  together cover more than 65,536 IPv4 addresses or 2^80 IPv6 addresses;
- holds a range that overlaps private, loopback, shared, link-local,
  multicast, documentation, benchmarking, 6to4, Teredo or NAT64 space, or an
  IPv6 range outside `2000::/3`.

A failed fetch (an HTTP error, no connection, a body over 512 KB, a redirect,
a refused list) also keeps the old list with its old age, so after four failed
runs in a row it goes stale and stops deciding anything. The vendors' own
lists sit well inside these limits.

**A match is only as good as the vendor's list.** An address in a list is
trusted because the vendor put it there. Bing's list, for one, includes `/28`s
in Microsoft Azure space; whoever holds an address the list names is verified
as Bingbot.

### What a request is charged as

Only the search-engine class is checked; a browser, an AI crawler or a script
never triggers a lookup.

| What the check says about the claim | Charged as | Ceiling with the defaults |
|---|---|---|
| **Verified**: the address is in the engine's fresh published list, or the name is under the engine's domain and resolves back to the address | Search engine | 600 a minute |
| **Proven false**: no PTR record, a PTR name outside the engine's domain, or a name that does not resolve back to the address; for DuckDuckBot, an IPv4 address outside DuckDuckGo's fresh list | No user agent | 60 a minute |
| **Not proven either way**: the lookup has only just started, could not start (the node is busy, the network used its lookup budget, the verifier is restarting), timed out or got a DNS error; DuckDuckBot while DuckDuckGo's list is missing or stale, or over IPv6; or the address is private, a `TRUSTED_PROXIES` address, or arrived through a forwarding header nothing trusts | Search engine, but never above the browser limit | 300 a minute |
| Verification is off (`KILN_CRAWLER_VERIFICATION=false`) | Search engine | 300 a minute (the default is 100% while verification is off) |

So only a verified address gets more than a browser, whatever the
search-engine percentage. A site's lower value applies in every row.

The smart 404 guard reads a claim DNS could not answer differently: a silent
reverse zone counts against the claim while the resolver works, and a silent
engine zone does not (see
[What counts, and what never does](ip-blocking.md#what-counts-and-what-never-does)
and [ADR 0054](decisions/0054-in-crawler-verification-a-silence-the-claimant-controls-counts-against-it-and-one-the-vendor-controls-does-not.md)).

**A request never waits for DNS.** The first request from a new address is
judged as "not proven" while a lookup starts in the background, and later
requests from that address are judged by its result. An address inside a
fresh published list needs no lookup, so its first request is verified too.

**Results are cached per node, per address.** A verified address is trusted for
6 hours, a proven false one is held for 1 hour, and a DNS error is retried after
5 minutes. Nothing is cached when no lookup was made. Each node keeps its own
cache, so a new node checks an address again. Verified addresses are kept apart
from the rest, up to 10,000 of them per node (and 50,000 rejections and DNS
errors), so a flood of fake claims from new addresses cannot push a real
crawler's result out (#2588).

**Each lookup is bounded.** At most three DNS queries per address: one PTR query,
then a forward query for at most two of the first three PTR names. The whole
lookup has a 3-second deadline. A node runs at most 16 lookups at a time and
queues none: a claim that arrives while 16 are running is left unchecked, and a
later request tries again. New lookups are also rate limited per network, so
one party cannot buy a lookup for every address it holds. A lookup left
unchecked because 16 were running does not count against these limits
(#2588):

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
5. **Let the node fetch the published lists.** One node fetches them over
   HTTPS (port 443) from `developers.google.com`, `www.bing.com`,
   `search.developer.apple.com` and `duckduckgo.com`; any node may be the one,
   so allow all of them. About a minute after the node starts, ask it what it
   holds:

   ```sh
   bin/kiln_cms rpc 'IO.inspect(KilnCMS.CrawlerVerification.Ranges.status())'
   ```

   Each engine with a list shows its URL, how many ranges it holds, how long
   ago it was fetched (in milliseconds, `nil` if never) and whether it is
   fresh. You should see something like this; the counts change whenever the
   vendors update their lists:

   ```
   %{
     apple: %{age_ms: 41213, count: 24, fresh?: true, source: "https://search.developer.apple.com/applebot.json"},
     bing: %{age_ms: 41213, count: 29, fresh?: true, source: "https://www.bing.com/toolbox/bingbot.json"},
     duckduckgo: %{age_ms: 41213, count: 486, fresh?: true, source: "https://duckduckgo.com/duckduckbot.json"},
     google: %{age_ms: 41213, count: 317, fresh?: true, source: "https://developers.google.com/static/crawling/ipranges/common-crawlers.json"}
   }
   ```

   `fresh?: false` with `count: 0` means the list was never fetched on this
   node or sent to it. Run it on any node: every node should show the same
   counts. For a health check, alert when an engine's `fresh?` is `false`, or
   on the `ranges_fetch` metric
   ([Observability](observability.md#crawler-verification)).

### What can go wrong

| What you see | What it means |
|---|---|
| `{:error, :timeout}` from step 3 | No DNS answer within 3 seconds: the node cannot reach its resolver, or the resolver cannot reach the internet. Open DNS egress, or turn verification off. |
| `{:error, :servfail}`, `{:error, :refused}` or another `{:error, _}` from step 3 | The resolver answered with an error. Same remedies. |
| `{:rejected, :no_ptr}` for an address you know is the crawler's | That address has no PTR record from your resolver's point of view. Check the address against the engine's own instructions above. |
| Log warning "Crawler verification: 20 DNS lookups in a row timed out or failed; check that this node can reach its DNS resolver, or set KILN_CRAWLER_VERIFICATION=false to turn verification off" | Logged once per node. Every claim is being judged "not proven", which keeps the search-engine ceiling up to the browser limit, so crawlers are not refused because of it. |
| Log warning "Crawler verification is at its concurrent-lookup limit; new search-engine claims go unchecked until a lookup finishes" | Logged once per node, the first time 16 lookups were already running. Unchecked claims are "not proven". Occasional is normal; a steady `kiln_cms_crawler_verification_skipped_count{reason="busy"}` means slow DNS. |
| `kiln_cms_delivery_unverified_crawler_count{reason="not_public"}` for most claims | The node sees a proxy's address, not the client's. Set `TRUSTED_PROXIES` (step 2). |
| Log warning "Crawler verification: google's published crawler IP ranges are missing or stale, so its claims fall back to DNS (DuckDuckBot's go unverified). Check that this node can reach the vendor over HTTPS, or set KILN_CRAWLER_RANGES=false to stop fetching them" | Logged once per engine per node by the 10-minute check, until that list is fresh again. Nothing is refused because of it: Google, Bing and Apple claims go to DNS, DuckDuckBot claims stay "not proven". Open HTTPS egress to the vendor (step 5), or turn the lists off. |
| Log warning "Crawler verification: could not refresh the published crawler IP ranges of duckduckgo; each keeps the list held before until it goes stale" | A fetch failed. `kiln_cms_crawler_verification_ranges_fetch_count{result}` says why: `http_error` (not a 200, including a redirect: the vendor may have moved its list), `transport_error` (no connection), `blocked` (the host resolved to an address `SafeFetch` refuses), `too_large`, or one of the reasons Kiln refused the list (`invalid`, `no_prefixes`, `too_many`, `too_broad`, `not_public`). The old list keeps working until it is 24 hours old. A moved URL can be pointed elsewhere in code config; see [For developers](#for-developers-the-range-list-configuration). |
| A real DuckDuckBot address is charged as no user agent, or blocked by the 404 guard | DuckDuckGo started crawling from an address that was not in its list when this node last fetched it. The next successful fetch, normally within 6 hours, fixes it; with fetches failing, the list goes stale within 24 hours and DuckDuckBot claims go back to "not proven". Remove the block on `/editor/ip-blocks`. |

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
per-site switch. It also turns off the published lists below, and nothing is
fetched from the four vendors.

### Turn the published lists off

To keep DNS verification but make no request to Google, Bing, Apple or
DuckDuckGo, set:

```sh
KILN_CRAWLER_RANGES=false
```

and restart. No list is read or fetched. Google, Bing and Apple claims are
checked by DNS alone, and DuckDuckBot claims are never verified nor proven
false: they keep the search-engine class, held to the browser limit, as before
#2586. Set it on every node.

To keep the lists but stop Kiln fetching them on its own, set
`KILN_CRAWLER_RANGES_CRON=false`. That removes the 6-hourly job **and** the
fetches a node queues at boot and when a list goes stale. A list then reaches a
node only from a peer, or from a fetch you queue yourself:

```sh
bin/kiln_cms rpc 'KilnCMS.CrawlerVerification.RangesWorker.new(%{}) |> Oban.insert() |> IO.inspect()'
```

Without such a fetch every list goes stale within a day, which is the same as
turning them off, with a warning logged once per engine on each node. A cron
expression that does not parse also removes the job and, like `false`, every
automatic fetch; it is reported on stderr at boot.

In dev the lists are off unless you start with `KILN_CRAWLER_RANGES=true`, so
`mix phx.server` makes no request to the vendors; with it set, the node queues
one fetch 20 seconds after boot. The test and end-to-end environments never
fetch them.

### For developers: the range list configuration

Code config, for a deployment that needs to point a list elsewhere (a vendor
that moved its URL before Kiln was updated, or a mirror inside your network):

```elixir
config :kiln_cms, KilnCMS.CrawlerVerification.Ranges,
  # Per engine: a URL replaces the built-in one, false drops that engine's
  # list. An engine left out keeps its default.
  sources: %{google: "https://mirror.example.com/common-crawlers.json", apple: false}
```

The other keys are `:enabled` (`true`), `:max_age_ms` (24 hours, how long a
list stays fresh), `:max_bytes` (524,288), `:max_prefixes` (5,000),
`:bootstrap?` (`true`, whether a node queues fetches of its own at boot and
when a list is stale) and `:bootstrap_after_ms` (20,000). A source is fetched
through `KilnCMS.SafeFetch`, so it must be a public address that answers 200
without a redirect; use HTTPS, since the list decides who is verified. See `KilnCMS.CrawlerVerification.Ranges` and
`KilnCMS.CrawlerVerification.Engines`.

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
  A claim proven false drops to 60 requests a minute; unchecked claims keep
  300, and verified ones get more (next item). No migration; rolling the pin
  back is safe and goes back to believing every claim.
- **Verified search engines get twice the browser limit by default (#2587).**
  An address DNS has verified as Googlebot, Google-InspectionTool, bingbot,
  Applebot, YandexBot or Baiduspider may make 600 requests a minute instead of 300; nothing else
  changes. Behind a proxy without `TRUSTED_PROXIES` no address is verified, so
  nothing changes there either. To keep 300, set
  `KILN_BOT_BUDGET_SEARCH_ENGINE_PERCENT=100` and restart. Rolling the pin back
  goes back to 300.
- **Kiln now fetches Google's, Bing's, Apple's and DuckDuckGo's published
  crawler IP lists every 6 hours (#2586), on by default.** It is an outbound
  HTTPS request from one node to `developers.google.com`, `www.bing.com`,
  `search.developer.apple.com` and `duckduckgo.com`, plus one about 20 seconds
  after a node starts while no list is fresh. Allow that egress on every node
  (any node may be the one that fetches), or set `KILN_CRAWLER_RANGES=false`.
  Blocked, nothing breaks: each list stays missing, claims are checked by DNS
  as before, and a warning is logged per engine. See
  [Published IP ranges](#published-ip-ranges).
- **DuckDuckBot is now verified, and can be proven false (#2586).** A
  DuckDuckBot claim from an address in DuckDuckGo's list gets the verified
  ceiling (600 a minute by default) where it had 300. One from an IPv4 address
  outside the list is charged as no user agent (60 a minute) and, with the 404
  guard on, counts toward the miss threshold. A real DuckDuckBot on an address
  DuckDuckGo added since the last fetch is treated that way until the next
  successful fetch: normally up to 6 hours, at most 24 if fetches fail, after
  which the list is stale and claims go back to "not proven". No migration;
  nothing is stored, so rolling the pin back is safe and goes back to DNS alone.
  In a cluster upgraded node by node, older nodes ignore the lists the new ones
  send.

## What this is not

- **Not access control.** Every class but the search-engine one is reachable by
  typing its user agent, and a search-engine claim keeps its ceiling (up to the
  browser limit) until DNS proves it false. Verification only decides how much
  an address may spend; it never lets anyone in.
- **Not a range check for every engine.** Only Google, Bing, Apple and
  DuckDuckGo publish lists. Yandex and Baidu are checked by DNS alone, and a
  Google, Bing or Apple address outside its list still goes to DNS. A list is
  only as trustworthy as its vendor's publishing: Kiln believes it, within the
  limits in [Published IP ranges](#published-ip-ranges).
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
