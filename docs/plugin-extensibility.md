# Runtime / marketplace extensibility — decision & marketplace design

**Status:** decision (amends nothing — it *ratifies* the stance D18/D4 already
took) plus a design for the "marketplace" future those decisions deferred.
**Issue:** [#333](https://github.com/The-Verscienta/kiln_cms/issues/333).
**Relies on:** `Kiln.Plugin` (D18, `docs/plugin-system-plan.md`), dynamic
content types (D17, `docs/dynamic-content-types-plan.md`), `Kiln.FieldType`,
declarative editorial automation (#342).

## TL;DR

> **Kiln does not hot-load arbitrary plugin *code* at runtime, by design.**
> A plugin is compile-time OTP code activated by one config line (D18). The
> "marketplace" is a catalog of **vetted, git-distributed, compile-time
> plugins** — Mix dependencies on `kiln_plugin`, or vendored into `projects/` when they need the core (#1909) — installers, not a code-execution sandbox — plus the parts of a
> live instance that are *already* extensible without code: dynamic content
> types (D17), the `Kiln.FieldType` registry, and declarative automation
> rules (#342). A genuine runtime-code story (out-of-process plugins, a WASM
> runtime) is a separate, dedicated, security-reviewed effort, deferred until
> a proven demand justifies it.

## 1. The decision: no runtime hot-loading of arbitrary code

The issue itself flags the instinct — "Hot-loading arbitrary OTP code is a big
security/stability surface." That instinct is correct and load-bearing.

### Why the BEAM makes this the wrong target

OTP genuinely supports hot code loading, so it is tempting to reach for it. The
problem is not *whether* code can be loaded — it is *what confines it once
loaded*:

- **There is no in-process sandbox on the BEAM.** Hot-loaded code runs in the
  *same node*, in the *same VM*, with the *same privileges* as core. A loaded
  module can call `System.cmd/2`, read or `:sys.get_state/1` any process,
  open the database with full credentials, spawn unlimited processes, or crash
  the scheduler. There is no capability boundary — no seccomp, no namespace,
  no per-module permission — that a plugin could be confined to. Erlang's
  distribution security model assumes *mutually trusting* nodes; it is not an
  isolation primitive.
- **Untrusted third-party code therefore means full compromise.** The moment
  arbitrary code from a marketplace runs in-node, every guarantee above it is
  void: an attacker's "star-rating widget" can exfiltrate secrets or tamper
  with published artifacts.
- **It contradicts what Kiln sells.** Kiln's differentiators — immutable
  published artifacts, supervision-tree reliability, content provenance
  (#4/#5) — all assume the node is *trusted*. Other CMS marketplaces
  (Strapi/Craft/Directus) run on Node/PHP VMs that *also* lack strong
  in-process isolation; they accept that risk because their trust story is
  weaker to begin with. Adopting their model would trade away exactly the
  property Kiln is built to offer.

Compile-time inclusion, by contrast, puts every line of a plugin through the
same review, `mix kiln.plugins.doctor`, CI gate, and release build as core
code. Trust is established *before* the code is in the node, which is the only
point at which the BEAM lets you establish it.

### What a genuine runtime-code story would require

This is not an incremental feature flag away — each option below is a major
architecture project with its own threat model, and all are explicitly
deferred until proven demand justifies the investment:

- **Out-of-process plugins.** Run untrusted extension code as a separate OS
  process (or container) behind an RPC/port boundary, with an explicit,
  narrow protocol (think Language Server Protocol, or `erlang:open_port/2`
  with a byte contract). The OS enforces the isolation the BEAM cannot.
- **Separate, restricted BEAM nodes.** Give plugins their own node with a
  constrained distribution channel and no shared ETS/Mnesia; the core node
  brokers every capability. Distribution hardening and a capability broker are
  the hard parts.
- **A WASM runtime (e.g. [Wasmex](https://hex.pm/packages/wasmex)).** Compile
  plugin logic to WebAssembly and run it in a sandbox with an explicit host
  ABI — memory-isolated, syscall-free by default, capabilities granted one at
  a time. The most promising path for *true* third-party code, but it forces a
  narrow value-passing ABI (no sharing Ash structs/PIDs), a defined extension-
  point surface, and resource metering. A dedicated effort, not a bolt-on.

None of these is required for the marketplace below, which delivers the
practical value of "extend my instance" without opening any of these fronts.

## 2. The marketplace: vetted compile-time plugins + data-driven runtime config

The realization behind this design: **most of what a "live marketplace"
delivers elsewhere, Kiln can offer as data or as vetted installers — with no
runtime code loading at all.**

### 2a. Catalog of vetted, distributable plugins

A "marketplace plugin" is an ordinary `Kiln.Plugin` (D18) kept in **its own
git repository**. It reaches a site one of two ways, and which one depends on
what it contributes:

| Shape | How it's installed | What it can contribute |
|---|---|---|
| **Mix dependency** — Hex, `git:` or `path:` | Depends on [`kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md), the package the plugin contract ships in (#1909); the site lists it in the overlay's `config/project_deps.exs` (#1967) | Blocks, field types (no colocated client hooks), spam checks, advisory checks, image backends, human-verification providers (`challenge_providers/0`, from `kiln_plugin` 1.4), security posture checks (`security_checks/0`, from `kiln_plugin` 1.4), nav items, supervision children, Oban queues; routes only to a LiveView that doesn't `use KilnCMSWeb`; plug routes (`plug_routes/0`, from `kiln_plugin` 1.4) to any Plug, needing only `plug` |
| **`projects/<name>/` overlay** | Vendored into the overlay and compiled inside the core | Everything above, plus content types (`KilnCMS.CMS.Content`), Ash domains, and LiveViews built on `KilnCMSWeb` |

A dependency compiles before the core and sees only its own dependencies, so
it can build on `kiln_plugin` but not on anything that lives in the core.
That is the whole split: a plugin that needs the core's repo, domains,
policies or web layer is an overlay.

1. **Add it** — as a dependency: one entry in the overlay's
   `config/project_deps.exs` (#1967), written as in a `mix.exs` deps list:
   `{:kiln_ratings, "~> 1.0"}` (Hex) or a `git:`/`path:` dep. The core's
   own `mix.exs` and `mix.lock` never change: while that file exists, Mix
   locks into `config/project.lock`, seeded from `mix.lock` so the core's
   dependencies stay at the release's versions. Both files are git-ignored
   in the core and committed in the overlay, like `config/project.exs`, and
   `mix kiln.update` re-seeds the lock when it moves the pin. An entry may
   not set `override: true`. As an overlay: copy, `git subtree` or
   `git submodule` the plugin's repository into `projects/<name>/` in your
   overlay, pinned to a tag.
2. **Register it** — one line: `config :kiln_cms, :plugins, [Ratings.Plugin]`
   (plus its domains in `:ash_domains`/`:content_domains` if it ships content
   types — Ash's own mix tasks read those keys directly).
3. **Verify** — `mix kiln.plugins.doctor` (already gates precommit) asserts the
   contract holds: domains registered, no block/field-type/queue name
   collisions, well-formed routes (plug routes: no core path, no overlap with
   another plugin's), and, for a dependency, that its
   `kiln_plugin` requirement accepts the version the core bundles. (The core
   takes `kiln_plugin` with `override: true`, so Mix itself never checks it.)
   With `config/project_deps.exs` it also fails a core dependency that moved
   in `config/project.lock`, notes a plugin installed there but not
   registered, and names each plugin's source.
4. **Discover what's installed** — `mix kiln.plugins.list` prints every
   installed plugin with its catalog metadata and contribution surface.
5. **Keep checking it after it ships** — **Operations → System → Plugins**
   (platform admins) compares each plugin from Hex with hex.pm (has the
   package changed there since this build, is the release retired, has the
   package had no release for 24 months, `KILN_PLUGIN_STALE_MONTHS`), with
   the security notices feed, and with the `kiln_plugin` this core bundles
   (does the plugin's requirement accept it). The Security posture page summarizes it
   as an Installed plugins line (#2244). **Check plugins now** re-asks
   instead of waiting for the cache. `mix kiln.plugins.list --health` does
   the same from the command line. There is no registry behind it: hex.pm
   and kilncms.dev's notices are the sources. An unreachable source makes a
   plugin unknown, never OK, and git and path plugins can't be checked
   against Hex. Asking hex.pm tells it the plugin's package name and
   version; `KILN_PLUGIN_HEALTH_CHECK=false` stops those requests
   (`KILN_UPDATE_CHECK=false` does too, unless the first is set), while the
   local `kiln_plugin` requirement check still runs. See
   [Check your installed plugins](security-posture.md#check-your-installed-plugins)
   and [Plugin system §7](plugin-system-plan.md#7-plugin-health-checks-2244).

The `mix kiln.gen.plugin <Name>` scaffold produces a distribution-shaped
skeleton in `projects/<name>/`; an overlay plugin is that directory, filled in
and published as its own git repository. A dependency plugin is an ordinary
Mix project depending on `kiln_plugin`: `mix kiln.gen.plugin <Name> --dep`
scaffolds one at `../<name>` (or `--path`), and `sdk/fixtures/dep_plugin` is
a worked, CI-compiled example.

#### Plug routes: webhooks, JSON endpoints, feeds (`plug_routes/0`, #2272)

`public_routes/0` mounts a LiveView page. For an endpoint with no page, such as
a webhook receiver, a small JSON API, a form handler or a feed variant, a
plugin declares `plug_routes/0` (`kiln_plugin` 1.4; a plugin using it requires
`{:kiln_plugin, "~> 1.4"}`). It is for content-adjacent endpoints; it is not a
place to build an application backend.

```elixir
@impl Kiln.Plugin
def plug_routes do
  [
    # {verb, path, plug_module, plug_opts}: a Phoenix controller is a Plug
    # whose opts is the action atom.
    {:post, "/hooks/ratings", KilnRatings.WebhookController, :create},
    {:get, "/ratings/summary.json", KilnRatings.SummaryPlug, []},
    # {:forward, path, plug_module, plug_opts}: everything below the path,
    # with the path stripped. A Plug.Router is the usual target.
    {:forward, "/ratings/feeds", KilnRatings.FeedRouter, []}
  ]
end
```

The verb is `:get`, `:post`, `:put`, `:patch`, `:delete` or `:match` (any
method). `:get` also answers `HEAD`. `plug_opts` is baked into the router at
compile time, so it must be a plain term (atoms, strings, numbers, lists,
maps), not a function or a pid. A route may not be written against
`Phoenix` itself: the contract needs only `plug`, so the plugin works as a
Mix dependency. `sdk/fixtures/dep_plugin` is a worked example of both shapes.

What the core does with it:

- **Placement.** Mounted before the content-delivery catch-alls, like
  `public_routes/0`, so a plugin path wins over a content slug of the same
  name. It cannot sit under `/editor`, `/api`, `/gql` or `/mcp`, or under any
  other first segment a core route already owns. The first segment must be
  static (`/hooks/:id` is fine, `/:thing/x` is not).
- **No session, no CSRF, no `accepts`.** The caller is a machine. There is no
  `current_user`: the plugin authenticates its own caller (an HMAC, a token),
  and nothing here is an admin or editor surface. No HTML or browser pipeline
  is offered; a plugin that needs a page uses `public_routes/0`.
- **Tenant.** The endpoint has already resolved the request's organization:
  `conn.assigns.current_org`. A plugin that reads or writes content must pass
  `tenant:` to Ash itself; nothing sets it for the plugin.
- **Rate limit.** Per client address, 300 requests a minute, in its own bucket
  (`:plugin_endpoint`), apart from the core APIs. It bounds floods, not
  guessing: authorization is the plugin's.
- **Raw body.** For a plugin path the request body is kept byte for byte in
  `conn.private[:raw_body]` for **any content type** (JSON, form, `text/plain`,
  `application/octet-stream`, XML, …), so an HMAC over the exact bytes can be
  verified. The body is read for you: `Plug.Conn.read_body/2` in the plugin
  returns `""`, and `conn.params` holds only the query and path params. A
  request that sends a body with no `content-type` is treated as
  `application/octet-stream`. The cap is 1 MB; over it the request is refused
  with `413` before it reaches the plugin (`Request Entity Too Large`, as plain
  text, or the JSON error envelope for a client that accepts JSON). Two
  exceptions: `multipart/*` is parsed into `conn.params` and has no raw bytes
  (and is spooled to disk under the endpoint's 8 MB limit before the plugin
  runs, so don't take multipart webhooks), and a body larger than 1 MB is not
  possible on a plugin path — large uploads belong behind an authenticated
  core API, not a plugin route. `GET` and `HEAD` carry no body.

  *Decision (#2272):* the core could have left types it has no parser for
  unread and let the plugin read them. It doesn't, because the plugin would
  then read with Plug's default 8 MB on a route nobody has authenticated yet,
  and signature verification would depend on the sender's content type.

- **Compile time.** A malformed entry stops the build with an error naming the
  plugin. `mix kiln.plugins.doctor` reports all of them at once, plus a path a
  core route owns, and any overlap, on whole path segments, with another
  plugin's plug or public routes (`/hooks` does not overlap `/hooks-extra`; a
  `:forward` overlaps everything below it). `mix kiln.plugins.list` and System
  → Plugins count the routes.

A plugin built against `kiln_plugin` older than 1.4 (or one that hand-rolls the
behaviour) has no such function; the core treats it as declaring none.

##### A webhook receiver: authenticate, tenant, actor

A plug route runs in the `:plugin_endpoint` pipeline, which has no session. So
`conn.assigns.current_user` is **never set**, and the tenant exists only as
`conn.assigns.current_org` (the endpoint resolved it from the Host header).
Nothing passes either to Ash for you, and tenancy fails open: a content call
without `tenant:` quietly runs against the default org, so a missing org is not
an error, it is a write into the wrong site. A plugin that touches content does
three things itself, and fails closed at each:

1. **Authenticate the caller.** An HMAC over the exact bytes, taken from
   `conn.private[:raw_body]`. Compare with `Plug.Crypto.secure_compare/2`.
2. **Take the tenant from `conn.assigns.current_org`** and pass it as `tenant:`
   on every Ash call.
3. **Name the actor** and pass it as `actor:`, so the resource's policies decide
   what the hook may do. Use a dedicated service account (an editor in the orgs
   it serves), not `authorize?: false`. The one unauthorized call is loading
   that account: a user can read only itself, and it is looked up by an id from
   operator configuration, never from the request.

```elixir
defmodule KilnRatings.WebhookPlug do
  @behaviour Plug
  import Plug.Conn

  # The plugin compiles before the core, so the core's modules are called at
  # run time. This silences the compiler's "undefined module" warning.
  @compile {:no_warn_undefined, [KilnCMS.CMS, KilnCMS.Accounts]}

  def init(action), do: action

  def call(conn, :webhook) do
    with {:ok, secret, actor_id} <- config(),
         :ok <- verify_signature(conn, secret),
         {:ok, org} <- fetch_org(conn),
         {:ok, actor} <- fetch_actor(actor_id),
         {:ok, event} <- decode(conn) do
      record(conn, event, actor, org)
    else
      {:error, status, message} -> send_resp(conn, status, message)
    end
  end

  # 1. Authenticate. The core keeps the raw body for every content type but
  #    multipart, which has none to sign, so it is refused rather than guessed at.
  defp verify_signature(conn, secret) do
    raw = conn.private[:raw_body]
    given = conn |> get_req_header("x-signature") |> List.first()
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw || ""), case: :lower)

    cond do
      not is_binary(raw) -> {:error, 400, "a raw body is required"}
      is_binary(given) and Plug.Crypto.secure_compare(given, expected) -> :ok
      true -> {:error, 401, "bad signature"}
    end
  end

  # 2. Tenant: the endpoint's, never a fallback.
  defp fetch_org(conn) do
    case conn.assigns[:current_org] do
      %{id: _} = org -> {:ok, org}
      _none -> {:error, 500, "no organization resolved"}
    end
  end

  # 3. Actor: a service account named by configuration.
  defp fetch_actor(actor_id) do
    case KilnCMS.Accounts.get_user(actor_id, authorize?: false) do
      {:ok, user} -> {:ok, user}
      _error -> {:error, 503, "webhook actor not found"}
    end
  end

  # Read, then write, both as the actor and in the tenant. Idempotent on the
  # provider's event id, so a redelivery finds the first delivery's draft.
  defp record(conn, %{"id" => id, "title" => title}, actor, org) do
    slug = "evt-" <> String.downcase(String.replace(id, ~r/[^A-Za-z0-9]+/, "-"))
    opts = [actor: actor, tenant: org]

    case KilnCMS.CMS.list_posts(Keyword.put(opts, :query, filter: [slug: slug])) do
      {:ok, [%{id: post_id}]} -> send_resp(conn, 200, post_id)
      {:ok, []} -> create(conn, %{title: title, slug: slug}, opts)
      {:error, error} -> error_resp(conn, error)
    end
  end

  defp create(conn, attrs, opts) do
    case KilnCMS.CMS.create_post(attrs, opts) do
      {:ok, post} -> send_resp(conn, 201, post.id)
      {:error, error} -> error_resp(conn, error)
    end
  end

  # A policy refusal is the actor lacking authority in this tenant: 403.
  defp error_resp(conn, %{__struct__: Ash.Error.Forbidden}), do: send_resp(conn, 403, "forbidden")
  defp error_resp(conn, _other), do: send_resp(conn, 422, "could not record the event")
end
```

(`config/0` reads the secret and the actor id from the plugin's own application
environment and answers `503` when either is missing, so an unconfigured hook
refuses instead of accepting anyone; `decode/1` parses the body and answers
`422` for a payload without the fields it needs.)

What the actor can do is whatever its membership of the request's org allows.
The same service account posting to a host of an org it does not belong to is
refused with `403`, and nothing is written, which is the point of passing both
`actor:` and `tenant:`. A service account is a normal user, so grant it the
least role the hook needs, in only the orgs it serves.

This is `KilnDepFixture.HookPlug`'s `:webhook` action in
`sdk/fixtures/dep_plugin`, exercised through the real router in
`test/kiln_cms_web/plugin_plug_routes_test.exs`: a signed delivery on a
non-default org host, a redelivery, a wrong, missing or re-serialised
signature, the wrong tenant, and an unconfigured hook.

#### Human-verification providers (#2249)

The operator's sign-in, registration and form checks
([human-verification.md](human-verification.md)) are drawn by one provider:
Turnstile and reCAPTCHA v2 are built in, and a plugin can add another with
`challenge_providers/0` (`kiln_plugin` 1.4; require `{:kiln_plugin, "~> 1.4"}`).
It works from a Mix dependency: the contract, `Kiln.Challenge.Provider`, is
in the SDK, and the provider reaches its verification endpoint through a
`:post` function the core hands it, so it needs no HTTP client.

```elixir
# The plugin's entry module
@impl Kiln.Plugin
def challenge_providers, do: [MyCaptcha.Provider]
```

```elixir
defmodule MyCaptcha.Provider do
  use Kiln.Challenge.Provider

  @origin "https://captcha.example.com"

  @impl Kiln.Challenge.Provider
  def id, do: "my_captcha"

  @impl Kiln.Challenge.Provider
  def label, do: "My Captcha"

  # Read once per node, never per request: return constants.
  @impl Kiln.Challenge.Provider
  def widget,
    do: %{
      script_url: @origin <> "/v1/api.js?render=explicit",
      global: "myCaptcha",
      action_option: "action",
      response_field: "my-captcha-response"
    }

  @impl Kiln.Challenge.Provider
  def csp_sources, do: %{script_src: [@origin <> "/v1/"], frame_src: [@origin], connect_src: []}

  @impl Kiln.Challenge.Provider
  def verify(token, opts) do
    post = Keyword.fetch!(opts, :post)

    case post.(@origin <> "/v1/verify", [{"secret", opts[:secret]}, {"response", token}]) do
      {:ok, %{status: 200, body: body}} -> judge(Jason.decode(body))
      {:ok, %{status: status}} when status == 429 or status >= 500 ->
        {:error, {:unavailable, :http_status}}
      {:ok, _refused} -> {:error, :invalid}
      {:error, :timeout} -> {:error, {:unavailable, :timeout}}
      {:error, _transport} -> {:error, {:unavailable, :transport}}
    end
  end

  # Report where the token was solved; the core decides whether that counts.
  defp judge({:ok, %{"success" => true} = answer}),
    do: {:ok, %{hostname: answer["hostname"], action: answer["action"]}}

  defp judge({:ok, %{"success" => false}}), do: {:error, :invalid}
  defp judge(_not_json), do: {:error, {:unavailable, :malformed_response}}
end
```

(`judge/1` decodes with Jason, which the plugin then depends on; any JSON
library will do.) `sdk/fixtures/dep_plugin` has a worked provider,
`KilnDepFixture.ChallengeProvider`, which the core's suite resolves and
verifies through the real transport.

What the core does with it:

- **Nothing until it is named.** The operator selects a provider with
  `CHALLENGE_PROVIDER=<id>`. The id is a lowercase letter, then up to 31 of
  `a-z`, `0-9` and `_`. A built-in's id (`turnstile`, `recaptcha`) always
  means the built-in, and two plugins should not share an id.
- **Checked once, then used as data.** The first time the named provider is
  needed on a node, the core runs `Kiln.Challenge.Provider.conformance/1`
  and memoises the result. Pages read only that: `id/0`, `label/0`,
  `widget/0` and `csp_sources/0` are never called on a request, so they must
  return constants. A provider that fails the check, or raises, leaves human
  verification **off** with a boot warning. Assert it in your own tests:
  `assert Kiln.Challenge.Provider.conformance(MyCaptcha.Provider) == :ok`.
- **The page policy.** `csp_sources/0` is added to the sign-in pages' policy
  and to every response that draws a form's widget, only while a check can
  be shown. Each source must be `https://host[:port][/path]` (no wildcards,
  keywords or quotes), and `script_url` must be covered by one of the
  `script_src` entries. Keep them as narrow as the widget allows: path-scope
  them when you can.
- **The browser half is data.** The core's own `Challenge` hook draws every
  provider the same way (`render(element, options)` on `global`), steered by
  `widget/0`'s `render_options`, `action_option`, `onload_param` and
  `interactive`. Headless front ends get the same fields from the API
  ([api.md](api.md#draw-the-widget-in-your-own-front-end)). The moduledoc of
  `Kiln.Challenge.Provider` describes every key.
- **The core enforces your claims.** Return `{:ok, %{hostname: ..., action:
  ...}}` with what your service reported. The core refuses a missing or
  foreign hostname while hostnames are checked (the default), and an action
  that is present and differs. A refusal must be one of `:invalid`,
  `:expired`, `:hostname_mismatch` or `:action_mismatch`; anything else,
  `:missing` and `:malformed` included, is read as `:invalid`. Report
  `{:unavailable, reason}` only when your service really could not answer:
  that is the one answer that can let a sign-in through, within the core's
  bounds.
- **Logs.** If your widget's own markup posts the token under a field
  (`response_field`), the core reads it as a fallback on form submissions
  and scrubs it from Sentry. It cannot add it to Phoenix's request-log
  filter at run time, so the operator gets a boot warning to add it; say so
  in your plugin's README.
- **Before deploying.** `mix kiln.plugins.doctor` runs the conformance check
  on every installed provider, flags an id that collides with a built-in or
  another plugin's, and, with `CHALLENGE_PROVIDER` set in its environment,
  checks that some installed provider answers to it. `mix kiln.plugins.list`
  and the System page count each plugin's providers.

A plugin built against `kiln_plugin` older than 1.4 has no
`challenge_providers/0`; the core treats it as declaring none.

#### Security posture checks (#2252)

The console's [Security posture](security-posture.md) page runs the core's
own checks and every plugin's `security_checks/0` (`kiln_plugin` 1.4; require
`{:kiln_plugin, "~> 1.4"}`). It works from a Mix dependency: the contract,
`Kiln.Security.Check`, is in the SDK, and a check is handed everything it may
use in a `Kiln.Security.Check.Context` (the site, the build environment, the
clock and the reader's locale; no actor).

```elixir
# The plugin's entry module
@impl Kiln.Plugin
def security_checks, do: [MyPlugin.WebhookSecretCheck]
```

Each check runs in its own process under its own deadline (`timeout/0`,
default one second, held to at most five): one that crashes, overruns or
answers something other than a result shows as "could not run", never as a
pass. Ids under `core.` are reserved, and of two plugins answering to one id
the first registered wins; `mix kiln.plugins.doctor` reports both, and
`mix kiln.plugins.list` counts each plugin's checks. A check's `facts` must
never carry a secret or a person's address. A plugin built against
`kiln_plugin` older than 1.4 has no `security_checks/0`; the core treats it
as declaring none.

### 2b. Catalog metadata (the "registry")

The registry is **cheap, declarative data carried by the plugin itself** — no
central service required for v1. Each plugin optionally declares:

| Field | Callback | Purpose |
|---|---|---|
| Name | `name/0` | Machine name (already required) |
| Version | `version/0` | Display/version pin (defaults to `nil`) |
| Summary | `summary/0` | One-line catalog description |
| Homepage | `homepage/0` | Repo / docs URL — **where screenshots, changelog and docs live** |

`Kiln.Plugins.manifests/0` collects these plus each plugin's *contribution
counts* (domains, blocks, field types, advisories, spam checks, image backends,
human-verification providers, security checks, nav items, admin, editor, public
and plug routes, queues, children) into plain maps — the data a catalog UI or `mix kiln.plugins.list`
renders. Screenshots and long-form docs deliberately live in the plugin's own
repository / README, **not** in the running node: the node carries a pointer
(`homepage/0`), not a media library.

**The curated index** — "which plugins are vetted" — is a governance artifact,
not a code feature: a docs table (or, later, a hosted static index) listing
approved plugins with their git coordinates (repository + tag) and homepage. Vetting is a
human review that a package is safe to compile in, exactly the bar core code
clears. This keeps the security property intact: nothing is "installed" until a
maintainer adds it to the build (a dependency line or a vendored `projects/`
directory) and re-releases.

**A hosted index** — that governance artifact, built out as a public catalog on
kilncms.dev with a submission path, a compile-and-`doctor` verification
pipeline and per-version compatibility data — is designed in
[Plugin registry on kilncms.dev](plugin-registry-plan.md) (#1447). It changes
nothing above: it distributes metadata and trust, never code, and is never in
the install path.

### 2c. What's already runtime-configurable without code

For the "extend a live instance *without a rebuild*" cases, Kiln already ships
the safe, data-driven answers — this is the real moat, because it delivers the
agility of a live marketplace while staying compile-time-safe:

- **Dynamic content types (D17).** Admins define a new content type and its
  fields from the UI, backed by the generic `Entry` resource — strings
  end-to-end, no runtime atoms or modules. This is the Directus/Strapi "create
  a collection live" capability *without* code loading.
- **Custom field types (`Kiln.FieldType`).** Plugin-contributed field types are
  compile-time code, but admins *select and configure* them per field at
  runtime in the fields admin (`/editor/fields`). A type declares `cast/2`
  plus how it edits: `input_type/0` + `input_attrs/1` for a single control, or
  `input_parts/1` for a **composite** value rendered as one labelled input per
  part and cast as a map. A part with `type: "select"` carries an
  `options: [{value, label}]` list (blank choice first), and any part may carry a
  translatable `help:` line shown under its control (a placeholder is not
  translatable). An optional `description/0` is shown under the type
  picker once an admin selects the type, next to the core types' own
  descriptions. A type that can be edited in more than one way (a number box
  or stars) lists those ways with the optional `widgets/1` (`kiln_plugin`
  1.4); admins then pick one per field under **Editor input**, and the type
  reads the pick back with `Kiln.FieldType.widget/2` (see "Offering a choice
  of editor input" under Plugins in
  [extending-content.md](extending-content.md), and
  [Choose how editors fill in a field](extending-content.md#choose-how-editors-fill-in-a-field)).
  The optional `graphql_kind/1` (`kiln_plugin` 1.4) names how the GraphQL API
  types the stored value (`:string`, `:int`, `:float`, `:boolean`, `:date`,
  `:datetime` or `:json`); a type without it is served as `:json`.

  A type that needs behaviour in the browser (an address type-ahead, a map
  picker) declares `input_hook/1` (#1918): the editor wraps its widget in an
  element carrying that `phx-hook`. The hook is a LiveView **colocated hook**
  in the type's own module, so it is bundled into the host's `app.js` at build
  time under a module-namespaced name — no runtime-loaded script, nothing new
  for the Content-Security-Policy. A hook that needs the server pushes
  `"kiln:field_event"`; the editor runs the type's `handle_input_event/3` in a
  task and answers with a `"kiln:field_reply"` push event, so API keys stay
  server-side and a slow lookup never blocks the editor. Hooks act on their own
  field's inputs and dispatch `input`; they do not see the form's changeset,
  and `cast/2` still validates what they fill in. `mix kiln.plugins.doctor`
  checks every named hook was actually bundled.

  Two implementations ship in-tree and are written against exactly this
  contract rather than special-cased in the host, so they double as reference
  examples: `KilnCMS.CMS.FieldTypes.Geolocation` (#428, composite) and
  `KilnCMS.CMS.FieldTypes.Computed` (#429, derived). Every in-tree type's name
  is reserved, and since 1.9 that includes `email`, `telephone`, `color`,
  `slug`, `time`, `json`, `range`, `key_value` and `link` as well as
  `geolocation`, `computed`, `datetime_range` and `recurrence`
  (`KilnCMS.CMS.FieldTypes.reserved/0` lists them with the core types).
  `mix kiln.plugins.doctor` rejects a plugin that claims one ("collides with
  a built-in field type"), the same way it rejects one claiming a core type,
  so a plugin or overlay type with one of the new names must be renamed
  before upgrading.
- **Declarative editorial automation (#342).** "When X, do Y" rules are Oban-
  backed **data**, authored in the admin UI — the safe substitute for the
  "run this script on publish" hooks that other marketplaces sell.

A plugin author reaches for compile-time code only for genuinely new *behavior*
(a new block renderer, a new integration worker); everything schema- or
rule-shaped is data an operator changes without a deploy.

## 3. Scope for this change

- **Decision documented** (this file) and cross-linked from
  `docs/plugin-system-plan.md` §5.
- **Lightweight registry**, implemented here:
  - optional `version/0` / `summary/0` / `homepage/0` metadata on the
    `Kiln.Plugin` contract (defaults keep every existing plugin valid);
  - `Kiln.Plugins.manifests/0` — the plain-data registry view;
  - `mix kiln.plugins.list` — local discovery of installed plugins.
- **Explicitly out of scope, by design:** runtime loading of arbitrary plugin
  code; a hosted marketplace service (since designed as a *catalog* in
  [Plugin registry on kilncms.dev](plugin-registry-plan.md), #1447);
  screenshot/media hosting in-node.
- **Deferred to a future dedicated effort:** any true third-party runtime-code
  sandbox (WASM / out-of-process), per §1.

Issue #333 stays **open** as the tracking issue for that future effort.
