defmodule KilnCMS.Forms.EmbedCeiling do
  @moduledoc """
  The operator's ceiling over what a tenant may open to framing (#1133).

  Since #648 an org admin can set `Form.embed_origins` (and since #1131 an
  org-wide `SiteEmbedSettings.embed_origins`) and open `/forms/:slug/embed`
  to any origin the `CspOrigins` grammar accepts — which quietly changed
  `EMBED_ORIGINS` from an *allowlist* into a *default*. That is the right
  call for the tenant's own risk (the party bearing the overlay-and-harvest
  exposure is the party choosing), but it left the operator with two states
  to express — closed by default, or open by default — and no way to say
  **"this list is the most a tenant may open."**

  `EMBED_ORIGINS_LOCKED` says exactly that, and nothing else. Unset, it is
  **auto** (#1618): on once a second organization exists, off before — see
  `locked?/0`.

    * **Off** — #1130/#1131 behaviour is unchanged. `EMBED_ORIGINS`
      is the default for forms and orgs that set no list of their own, and a
      tenant's own list replaces it outright.
    * **On** — `EMBED_ORIGINS` is also the ceiling. A tenant's list may
      *narrow* it (`[]`, or a subset) but every entry must be covered by it:
      an admin's write naming an origin outside it is refused at the
      validation, and the served `frame-ancestors` is clamped to the ceiling
      as well, so a list written before the cap was turned on cannot keep the
      page wider than the operator now allows. `EMBED_ORIGINS=*` under the
      cap is a ceiling of everything, i.e. no cap; `EMBED_ORIGINS` unset under
      the cap is a ceiling of *nothing* — same-origin only, deployment-wide,
      whatever any tenant writes.

  Two rungs, one boundary: the cap applies to `Form.embed_origins` and to
  `SiteEmbedSettings.embed_origins` alike, because either one is concatenated
  into the same header. It does **not** apply to the operator's own list —
  `EMBED_ORIGINS` is the ceiling, not something under it.

  ## What "covered" means

  A tenant entry is inside the ceiling when some ceiling entry matches it the
  way a CSP host source would: same scheme (a scheme-less ceiling entry covers
  either), same port (`*` covers any; absent covers absent), and a host that is
  equal or — for a `*.`-wildcarded ceiling entry — a proper subdomain of it
  (CSP's reading: `*.acme.com` does not match `acme.com` itself). A
  wildcarded *tenant* entry (`https://*.acme.com`, which `CspOrigins` admits) is
  covered only by a wildcard at least as wide (`https://*.acme.com` or
  `https://*.com`-shaped, which the operator grammar admits and the tenant
  grammar does not); a plain `https://acme.com` in the ceiling does not cover
  it, because it would grant every subdomain the operator did not name.

  ## Why the refusal names the offender and not the ceiling

  The validation error lists the origins that were refused, never the
  ceiling itself: on a multi-org deployment `EMBED_ORIGINS` is the union of
  every org's embedders, and printing it would let one org's admin enumerate
  another org's partners — the disclosure #1130 deliberately avoided when it
  stopped naming the deployment default in the Embed tab. The remedy for the
  admin is "ask your operator", and that is what the message says.

  ## Where it is enforced

    * `KilnCMS.CMS.Validations.EmbedCeiling` — the write, on both resources.
    * `KilnCMS.Forms.EmbedPolicy.effective/1` — the read, via `clamp/1`,
      after the org rung has been resolved. Both `KilnCMSWeb.FormController`
      and the builder's Embed tab already go through `effective/1`, so the
      served header and what the admin is shown move together.
  """

  import Ecto.Query, only: [from: 2]

  @doc """
  Whether framing is capped at `EMBED_ORIGINS` (#1133) — the one reader of
  `EMBED_ORIGINS_LOCKED`. Both write validations, the served header
  (`KilnCMS.Forms.EmbedPolicy`), the builder's Embed tab and
  `/editor/forms/settings` all ask this, so they cannot disagree.

  Three settings (#1618), from `setting/0`:

    * `true` — always capped.
    * `false` — never capped: the pre-0.11 default, and the way back to it.
    * `:auto` (unset — the default) — capped if and only if more than one
      organization exists. With one org the operator and the org admin are the
      same party, so an org admin's list is the operator's choice. With two, an
      org admin decides who may frame that org's forms, and the operator's
      `EMBED_ORIGINS` should be the most any tenant may open.

  Auto reads `KilnCMSWeb.Tenant.OrgCount`'s cached verdict — the same one
  `TENANT_STRICT_HOST` reads (#1547), never a second count — so the create that
  makes a deployment multi-org caps it at once, on every node, with no restart.

  ## Fail direction: `:unknown` counts as locked

  `:unknown` is a node that has not managed to count its organizations yet
  (booted with Postgres unreachable; it recounts every 30 seconds). Treating
  it as locked matches `TENANT_STRICT_HOST`, and for the same asymmetry:
  unlocked-but-actually-multi serves a tenant's list *wider* than the operator
  allows, which is the overlay-and-harvest surface #562 closed and cannot be
  taken back from a visitor who already submitted into it; locked-but-actually
  -single narrows a single-org install's embeds to `EMBED_ORIGINS` until the
  count lands — the database it needs is the one the embed page needs too, so
  the window is the recount interval after an outage — and refuses a save
  the admin can simply retry.
  """
  @spec locked?() :: boolean()
  def locked? do
    case setting() do
      :auto -> KilnCMSWeb.Tenant.OrgCount.verdict() != :single
      explicit -> explicit
    end
  end

  @doc """
  The configured `EMBED_ORIGINS_LOCKED`: `true`, `false`, or `:auto` when unset.

  Anything that is not a boolean is `:auto`. `KilnCMS.Config.Env.fetch/1`
  already leaves an unrecognized spelling unset, so this only matters for an
  overlay's own `config :kiln_cms, :embed_origins_locked`, and auto is the
  default that value would otherwise have replaced.
  """
  @spec setting() :: boolean() | :auto
  def setting do
    case Application.get_env(:kiln_cms, :embed_origins_locked, :auto) do
      explicit when is_boolean(explicit) -> explicit
      _auto -> :auto
    end
  end

  @doc """
  How many stored allowlists the cap is cutting down right now: forms whose own
  `embed_origins`, and orgs whose `SiteEmbedSettings.embed_origins`, name at
  least one origin outside the ceiling — `%{forms: n, sites: m}`, or `:unknown`
  when the database cannot answer.

  Zero for both whenever the cap is off or the ceiling is `:all`. When it is
  on, those rows are not rewritten: `KilnCMS.Forms.EmbedPolicy` drops the
  uncovered entries from the served `frame-ancestors` (all of them, with
  `EMBED_ORIGINS` unset), so a partner site that used to frame the form gets
  a blank iframe. That is what the boot warning and `/editor/system` report
  (#1618) — the cap turning on by itself is exactly when nobody decided it.

  Deployment-wide by design, so it reads the two tables directly rather than
  through a tenant-scoped action, and only the one column; the answer is two
  counts, never an origin or an org. Total, like `KilnCMSWeb.Tenant.org_count/0`:
  a boot check or a page render must not fail because Postgres did.
  """
  @spec stored_overreach() :: %{forms: non_neg_integer(), sites: non_neg_integer()} | :unknown
  def stored_overreach do
    with true <- locked?(),
         ceiling when is_list(ceiling) <- ceiling() do
      KilnCMS.Config.Report.probe(:unknown, fn ->
        %{
          forms: count_overreaching("forms", ceiling),
          sites: count_overreaching("site_embed_settings", ceiling)
        }
      end)
    else
      _off_or_all -> %{forms: 0, sites: 0}
    end
  end

  @doc """
  The operator-facing warning for `stored_overreach/0`, or `nil` when there is
  nothing to say (cap off, ceiling `:all`, every stored list covered, or the
  database could not answer — not evidence of anything). Logged at boot by
  `KilnCMS.Application` and when the organization that turns an unset cap on
  is created (`KilnCMS.Accounts.Changes.WarnEmbedOverreach`); `/editor/system`
  renders the same counts.
  """
  @spec overreach_warning() :: String.t() | nil
  def overreach_warning do
    case stored_overreach() do
      %{forms: forms, sites: sites} when forms + sites > 0 ->
        "EMBED_ORIGINS caps which sites may frame forms on this deployment " <>
          "(#{cause()}), and #{forms} form allowlist(s) and #{sites} site-wide " <>
          "embed default(s) name sites outside it. Those entries are dropped from " <>
          "the served frame-ancestors, so those sites now get a blank iframe" <>
          closed_suffix() <>
          ". Add the sites to EMBED_ORIGINS, or set EMBED_ORIGINS_LOCKED=false to " <>
          "let each site's own list stand; see docs/forms.md."

      _nothing_or_unknown ->
        nil
    end
  end

  defp cause do
    case setting() do
      :auto -> "EMBED_ORIGINS_LOCKED is unset, which caps once a second organization exists"
      _true -> "EMBED_ORIGINS_LOCKED=true"
    end
  end

  defp closed_suffix do
    case ceiling() do
      [] ->
        ". EMBED_ORIGINS is unset, so the cap is same-origin only and no other site may frame any form"

      _listed ->
        ""
    end
  end

  # Only non-empty lists can reach outside anything; `nil` inherits the
  # ceiling itself and `[]` is same-origin.
  defp count_overreaching(table, ceiling) do
    from(r in table,
      where: not is_nil(r.embed_origins) and fragment("cardinality(?) > 0", r.embed_origins),
      select: r.embed_origins
    )
    |> KilnCMS.Repo.all()
    |> Enum.count(&(outside(&1, ceiling) != []))
  end

  @doc """
  The ceiling itself: `:all`, or the operator's `EMBED_ORIGINS` list — the same
  value `KilnCMSWeb.Embed` serves as the deployment default. `[]` (unset or
  refused as malformed) is a ceiling of same-origin only.
  """
  @spec ceiling() :: :all | [String.t()]
  def ceiling do
    case Application.get_env(:kiln_cms, :embed_origins, []) do
      :all -> :all
      list when is_list(list) -> list
      _other -> []
    end
  end

  @doc """
  The entries of `origins` that fall outside the ceiling — `[]` when the cap is
  off, when the ceiling is `:all`, or when every entry is covered.

  Order-preserving, so an error message reads back what the admin typed.
  """
  @spec outside([String.t()]) :: [String.t()]
  def outside(origins) when is_list(origins) do
    if locked?(), do: outside(origins, ceiling()), else: []
  end

  @doc "Same as `outside/1`, against an explicit ceiling — the pure half."
  @spec outside([String.t()], :all | [String.t()]) :: [String.t()]
  def outside(_origins, :all), do: []

  def outside(origins, ceiling) when is_list(origins) and is_list(ceiling) do
    parsed_ceiling = ceiling |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1)

    Enum.reject(origins, fn origin ->
      case parse(origin) do
        nil -> false
        entry -> Enum.any?(parsed_ceiling, &entry_covers?(&1, entry))
      end
    end)
  end

  @doc """
  `origins` with everything outside the ceiling removed — the served list.
  Identity when the cap is off. `[]` stays `[]`; a list clamped to nothing is
  `[]` too, which `KilnCMSWeb.Embed.frame_ancestors/1` renders as `'self'`.
  """
  @spec clamp([String.t()]) :: [String.t()]
  def clamp(origins) when is_list(origins) do
    case outside(origins) do
      [] -> origins
      out -> Enum.reject(origins, &(&1 in out))
    end
  end

  @doc """
  Whether one ceiling entry covers one tenant entry, both as strings. Public so
  the matching rule can be asserted on its own, entry by entry.
  """
  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(ceiling_entry, origin) when is_binary(ceiling_entry) and is_binary(origin) do
    case {parse(ceiling_entry), parse(origin)} do
      {nil, _} -> false
      {_, nil} -> false
      {c, o} -> entry_covers?(c, o)
    end
  end

  # ── matching ────────────────────────────────────────────────────────────────

  # scheme (optional), host (may be `*.`-prefixed, or IPv6 in brackets), port
  # (optional, or `*`), and an ignored path — the CSP host-source shape both
  # grammars are subsets of. Anchored `\A`/`\z` for the reason `CspOrigins`
  # gives: `$` matches before a trailing newline in PCRE.
  @entry ~r"\A(?:([a-z][a-z0-9+.\-]*)://)?(\[[^\]]+\]|[^:/\s]+)(?::(\d{1,5}|\*))?(?:/.*)?\z"i

  defp parse(entry) when is_binary(entry) do
    case Regex.run(@entry, String.trim(entry)) do
      [_, scheme, host, port] -> build(scheme, host, port)
      [_, scheme, host] -> build(scheme, host, "")
      _ -> nil
    end
  end

  defp parse(_entry), do: nil

  defp build(scheme, host, port) do
    %{
      scheme: if(scheme == "", do: nil, else: String.downcase(scheme)),
      host: String.downcase(host),
      port: if(port == "", do: nil, else: port)
    }
  end

  defp entry_covers?(%{} = c, %{} = o) do
    scheme_covers?(c.scheme, o.scheme) and port_covers?(c.port, o.port) and
      host_covers?(c.host, o.host)
  end

  defp scheme_covers?(nil, _origin_scheme), do: true
  defp scheme_covers?(scheme, scheme), do: true
  defp scheme_covers?(_ceiling, _origin), do: false

  defp port_covers?("*", _origin_port), do: true
  defp port_covers?(port, port), do: true
  defp port_covers?(_ceiling, _origin), do: false

  # `*` alone as a host is `:all` at the parse_env level and refused inside a
  # list, so it never reaches here as a ceiling entry — but if it did, it must
  # not read as "covers nothing" and it must not read as "covers everything"
  # by accident either. Explicit, and false: a `*` mixed into a list is the
  # shape `parse_env/1` discards the whole value for.
  defp host_covers?("*", _origin_host), do: false

  defp host_covers?("*." <> suffix, "*." <> origin_suffix),
    do: origin_suffix == suffix or String.ends_with?(origin_suffix, "." <> suffix)

  # Subdomains only, as CSP reads it: `*.acme.com` does not match `acme.com`
  # itself, so a ceiling of `https://*.acme.com` does not cover a tenant's
  # `https://acme.com` — the operator names the apex separately if they mean it.
  defp host_covers?("*." <> suffix, origin_host),
    do: String.ends_with?(origin_host, "." <> suffix)

  # A wildcarded tenant entry against a plain ceiling host: not covered, however
  # the suffixes line up — it would grant subdomains the operator did not name.
  defp host_covers?(_ceiling_host, "*." <> _rest), do: false

  defp host_covers?(host, host), do: true
  defp host_covers?(_ceiling_host, _origin_host), do: false
end
