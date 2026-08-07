defmodule KilnCMSWeb.MissedPathTracking do
  @moduledoc """
  Records a delivery 404 as an aggregated counter (#472).

  Called from the one funnel every HTML URL miss passes through
  (`KilnCMSWeb.ContentController`'s `not_found/2`), after the alias table, the
  redirect table and the paywall teaser have all missed — so a row here really
  is a path nothing on the site can serve.

  The path comes from the **caller**, not from `conn.request_path`. It is the
  same string `KilnCMS.CMS.Redirects.resolve/3` was just asked for: built from
  routed params, so empty segments have collapsed (`//blog//x` and `/blog/x` are
  one path, not two rows) and `%xx` escapes are decoded (`/caf%C3%A9` records as
  `/café`). Recording the raw request target instead would list paths whose
  one-click redirect could never fire, and would hand an attacker an unlimited
  supply of distinct-looking rows for one URL.

  Three properties matter, and all three are about not letting a 404 counter
  become a liability:

    * **Off the request path.** The upsert runs in a supervised, unlinked task,
      exactly like `KilnCMSWeb.ViewTracking` — a slow pool or a crawler spike
      drops counters (`start_child` → `{:error, :max_children}`) rather than
      queueing delivery behind them. Failures — including a supervisor that is
      momentarily down — are swallowed: a 404 must render during an outage.
    * **Junk-filtered.** Most anonymous 404 traffic is vulnerability probing
      (`/wp-login.php`, `/.env`, `/static/app.js`), which is noise in a list
      whose purpose is "which of *my* URLs broke". Probe-shaped paths are
      dropped before any DB work.
    * **Capped, by eviction rather than refusal.** Anyone can ask for a million
      distinct paths. Once an org is at `MissedPath.max_paths/0`, a new path
      evicts the **least-requested** row instead of being turned away. Refusing
      would let one cheap flood pin the table full of junk and permanently deny
      the feature — with eviction, displacing a genuine row costs an attacker
      more traffic than that row has, which is exactly the bound the `:delivery`
      rate limit puts a price on.

  Privacy: the path and the request locale, nothing else — no IP, user agent,
  referrer or actor is read here, let alone stored.
  """

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.MissedPath

  # Extensions that mark a request as a probe or an asset fetch rather than a
  # page an editor could redirect. Deliberately a denylist, not an allowlist:
  # extension-less slugs are the normal case, and `.html`/`.htm` — the legacy
  # paths most worth capturing after a migration off a static site — stay
  # recordable precisely because they are not listed here. `.php` is: classic
  # WordPress permalinks don't end in it, so in practice every `.php` miss is
  # `/wp-login.php`-shaped probing.
  @junk_extensions ~w(
    asp aspx bak cgi conf css dll env exe gif gz ico ini jpeg jpg js json jsp
    log map pdf pem php php5 php7 phtml pl png py rb sh sql svg tar toml ttf
    txt webp woff woff2 xml yaml yml zip
  )

  # Path prefixes that are never site content: agent/browser well-knowns and the
  # standard probe roots. Matched against the normalized (trailing-slash-free)
  # path, so each is listed without one — `/.git` and `/.git/config` both hit.
  # `/wp-content` is deliberately absent: after a WordPress migration those are
  # real inbound links worth redirecting.
  @junk_prefixes ~w(/.well-known /.git /vendor /cgi-bin /phpmyadmin)

  # Longer than any real URL an editor would want to redirect; a path this long
  # is a buffer-probe or a fuzzer.
  @max_path_length 255

  @doc """
  Record `path` as a miss for `org_id`, best-effort.

  Always returns `:ok` — the caller is about to render a 404 and must not be
  affected by anything here.
  """
  @spec track(String.t(), String.t(), Ash.UUID.t()) :: :ok
  def track(path, locale, org_id) do
    normalized = normalize(path)

    if MissedPath.enabled?() and recordable?(normalized),
      do: dispatch(normalized, locale, org_id)

    :ok
  end

  # `:async_analytics` is on in prod/dev but off under test, where a detached
  # task would run outside the ExUnit SQL sandbox connection (leaking a
  # connection past the owning test and racing assertions).
  #
  # `start_child/2` is a `GenServer.call`, so a supervisor that is restarting
  # exits the caller — and this one sits on the *error* path, which has to
  # survive exactly that kind of degradation.
  defp dispatch(path, locale, org_id) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
        record(path, locale, org_id)
      end)
    else
      record(path, locale, org_id)
    end
  catch
    :exit, _reason -> :ok
  end

  # The cap is applied here rather than in the resource because it is a
  # *recording* policy, not a data invariant — and because this runs inside the
  # task, so it never costs the request anything. The existence check is a point
  # read on the unique index; the count and the eviction only run for a path
  # that is genuinely new, against a table the cap keeps small by construction.
  defp record(path, locale, org_id) do
    opts = [authorize?: false, tenant: org_id]

    if known?(path, locale, opts) or make_room(opts) do
      CMS.record_missed_path(%{path: path, locale: locale}, opts)
    end
  rescue
    _ -> :ok
  end

  defp known?(path, locale, opts) do
    MissedPath
    |> Ash.Query.filter(path == ^path and locale == ^locale)
    |> Ash.exists?(opts)
  end

  # True once there is room for a new row. At the cap, evict the least-requested
  # row (oldest first among equals) — an attacker's one-hit junk is exactly what
  # that selects, while a URL real visitors keep hitting can only be displaced by
  # a path with *more* real traffic behind it.
  defp make_room(opts) do
    if Ash.count!(MissedPath, opts) < MissedPath.max_paths() do
      true
    else
      evict(opts)
    end
  end

  defp evict(opts) do
    MissedPath
    |> Ash.Query.sort(count: :asc, last_seen_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(opts)
    |> case do
      [row] -> Ash.destroy!(row, opts) == :ok
      [] -> true
    end
  end

  # `Plugs.SetLocale` has already stripped any locale prefix and the caller's
  # path never carries a query string, so normalization is just the trailing
  # slash — which is what makes a row droppable straight into the redirect form.
  defp normalize("/"), do: "/"
  defp normalize(path) when is_binary(path), do: String.trim_trailing(path, "/")
  defp normalize(_path), do: ""

  defp recordable?(path) do
    String.starts_with?(path, "/") and
      byte_size(path) <= @max_path_length and
      not String.contains?(path, <<0>>) and
      not junk_prefix?(path) and
      not junk_extension?(path)
  end

  defp junk_prefix?(path) do
    downcased = String.downcase(path)
    Enum.any?(@junk_prefixes, &(downcased == &1 or String.starts_with?(downcased, &1 <> "/")))
  end

  # A dot in the last segment with nothing usable after it (`/foo.`) is as
  # probe-shaped as a listed extension, so it counts as junk too.
  defp junk_extension?(path) do
    case path |> Path.basename() |> String.split(".") do
      [_no_extension] -> false
      segments -> String.downcase(List.last(segments)) in ["" | @junk_extensions]
    end
  end
end
