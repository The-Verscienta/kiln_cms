defmodule KilnCMS.SecurityTxt do
  @moduledoc """
  A site's `security.txt` (RFC 9116, #1873): the cached read of its
  `KilnCMS.CMS.SiteSecurityTxt` row, the renderer, and the value rules the
  write-time validation and the renderer share.

  `resolve/1` answers `{:ok, settings}`, `:unconfigured` (no row, or no
  contact — the controller's 404) or `:unavailable` (the row could not be read;
  uncached, the controller's 503). `render/2` takes the settings and the
  canonical URL, which is derived from the request's site host at serve time
  rather than stored, so a site that moves to a custom domain names the new
  host at once.

  ## Why every value is re-checked when rendering

  The file is `Field: value` lines. A value containing a line break would be a
  second field — a forged `Contact:` or `Expires:` — so `safe_uri?/1` is the
  rule at write time (`KilnCMS.CMS.Validations.SecurityTxt`) and again here,
  where a value that fails it is dropped instead of written. A row seeded or
  restored around the validation can then still not inject a line.
  """

  alias KilnCMS.Accounts.Organization

  @ttl :timer.minutes(5)

  @encryption_schemes ~w(openpgp4fpr: dns:)

  # One line of printable, non-space ASCII: what a URI is (RFC 3986), and
  # nothing that could end a line — no CR, LF, NEL, U+2028/9, tab or space.
  @uri_chars ~r/\A[\x21-\x7E]+\z/

  # A BCP 47 language tag, loosely: alphanumeric subtags joined by hyphens.
  @language_tag ~r/\A[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*\z/

  defmodule Settings do
    @moduledoc "The resolved, render-ready values of a site's `security.txt`."
    @enforce_keys [:contacts, :expires_on]
    defstruct contacts: [],
              expires_on: nil,
              policy_url: nil,
              preferred_languages: [],
              encryption_url: nil,
              acknowledgments_url: nil

    @type t :: %__MODULE__{
            contacts: [String.t()],
            expires_on: Date.t() | nil,
            policy_url: String.t() | nil,
            preferred_languages: [String.t()],
            encryption_url: String.t() | nil,
            acknowledgments_url: String.t() | nil
          }
  end

  @doc """
  The site's resolved `security.txt` settings, cached per org and busted by
  `KilnCMS.CMS.Changes.BustSecurityTxt` after a write.
  """
  @spec resolve(Organization.t()) :: {:ok, Settings.t()} | :unconfigured | :unavailable
  def resolve(%Organization{id: org_id}) do
    # The row is world-readable by policy; the system actor needs no grant of
    # its own (the `KilnCMS.Branding` read). `authorize_with: :error` keeps a
    # later, narrower read policy from caching a refusal as "no file".
    actor = KilnCMS.OrgSettings.system(:security_txt)

    KilnCMS.OrgSettings.resolve(org_id,
      cache_key: KilnCMS.Cache.security_txt_key(org_id),
      ttl: @ttl,
      read: &KilnCMS.CMS.list_site_security_txt(tenant: &1, actor: actor, authorize_with: :error),
      build: &build/1,
      fallback: fn -> :unavailable end,
      label: "security.txt"
    )
  end

  @doc false
  # The cached value for a row (or `nil`). Never `nil` itself — see
  # `KilnCMS.OrgSettings`: a `nil` would not be cached.
  @spec build(struct() | nil) :: {:ok, Settings.t()} | :unconfigured
  def build(nil), do: :unconfigured

  def build(row) do
    case Enum.filter(row.contacts || [], &contact?/1) do
      [] ->
        :unconfigured

      contacts ->
        {:ok,
         %Settings{
           contacts: contacts,
           expires_on: row.expires_on,
           policy_url: row.policy_url,
           preferred_languages: row.preferred_languages || [],
           encryption_url: row.encryption_url,
           acknowledgments_url: row.acknowledgments_url
         }}
    end
  end

  @doc """
  The file body for `settings`, with `canonical_url` as its `Canonical` field.
  Fields are written in RFC 9116's order of appearance; any value that is not
  a safe single-line URI (or language tag) is left out rather than written.
  """
  @spec render(Settings.t(), String.t()) :: String.t()
  def render(%Settings{} = settings, canonical_url) when is_binary(canonical_url) do
    [
      Enum.map(settings.contacts, &{"Contact", &1, contact?(&1)}),
      [{"Expires", expires(settings.expires_on), not is_nil(settings.expires_on)}],
      [
        {"Encryption", settings.encryption_url, encryption?(settings.encryption_url || "")}
      ],
      [
        {"Acknowledgments", settings.acknowledgments_url,
         https?(settings.acknowledgments_url || "")}
      ],
      [{"Preferred-Languages", languages(settings.preferred_languages), true}],
      [{"Canonical", canonical_url, https_or_http?(canonical_url)}],
      [{"Policy", settings.policy_url, https?(settings.policy_url || "")}]
    ]
    |> List.flatten()
    |> Enum.flat_map(fn
      {name, value, true} when is_binary(value) and value != "" -> ["#{name}: #{value}\n"]
      _skipped -> []
    end)
    |> IO.iodata_to_binary()
  end

  @doc "The canonical URL of `org`'s file, on its own host."
  @spec canonical_url(Organization.t()) :: String.t()
  def canonical_url(%Organization{} = org),
    do: KilnCMSWeb.Tenant.base_url(org) <> "/.well-known/security.txt"

  @doc """
  How close `expires_on` is to lapsing, as of `today`: `:expired` once the
  date has passed, `:expiring` within 30 days, `:too_far` beyond the year
  RFC 9116 §2.5.5 recommends, otherwise `:ok` (or `:unset`).
  """
  @spec expiry_status(Date.t() | nil, Date.t()) :: :unset | :expired | :expiring | :too_far | :ok
  def expiry_status(nil, _today), do: :unset

  def expiry_status(%Date{} = expires_on, %Date{} = today) do
    days = Date.diff(expires_on, today)

    cond do
      days < 0 -> :expired
      days <= 30 -> :expiring
      days > 366 -> :too_far
      true -> :ok
    end
  end

  # RFC 3339, the last second of the chosen day in UTC.
  defp expires(nil), do: nil
  defp expires(%Date{} = date), do: Date.to_iso8601(date) <> "T23:59:59Z"

  defp languages(tags) do
    case Enum.filter(tags || [], &language_tag?/1) do
      [] -> nil
      tags -> Enum.join(tags, ", ")
    end
  end

  # --- value rules (shared with `KilnCMS.CMS.Validations.SecurityTxt`) -------

  @doc "A single line of printable, non-space ASCII — nothing that can end a line."
  @spec safe_uri?(term()) :: boolean()
  def safe_uri?(value) when is_binary(value), do: Regex.match?(@uri_chars, value)
  def safe_uri?(_value), do: false

  @doc "A `Contact` value: a safe `mailto:`, `https://` or `tel:` URI."
  @spec contact?(term()) :: boolean()
  def contact?("mailto:" <> address = value),
    do: safe_uri?(value) and String.contains?(address, "@")

  def contact?("https://" <> _rest = value), do: https?(value)
  def contact?("tel:" <> number = value), do: safe_uri?(value) and number != ""
  def contact?(_value), do: false

  @doc "An `Encryption` value: a safe `https://`, `openpgp4fpr:` or `dns:` URI."
  @spec encryption?(term()) :: boolean()
  def encryption?("https://" <> _rest = value), do: https?(value)

  def encryption?(value) when is_binary(value),
    do:
      safe_uri?(value) and
        Enum.any?(@encryption_schemes, &scheme_with_body?(value, &1))

  def encryption?(_value), do: false

  @doc "A safe `https://` URL with a host."
  @spec https?(term()) :: boolean()
  def https?(value) when is_binary(value) do
    safe_uri?(value) and
      match?(
        {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "",
        URI.new(value)
      )
  end

  def https?(_value), do: false

  @doc "A BCP 47 language tag."
  @spec language_tag?(term()) :: boolean()
  def language_tag?(value) when is_binary(value), do: Regex.match?(@language_tag, value)
  def language_tag?(_value), do: false

  # The canonical URL comes from the deployment's own base URL, which is `http`
  # in development; it is still never anything but one line.
  defp https_or_http?(value),
    do:
      safe_uri?(value) and
        match?({:ok, %URI{scheme: s}} when s in ["https", "http"], URI.new(value))

  defp scheme_with_body?(value, scheme),
    do: String.starts_with?(value, scheme) and byte_size(value) > byte_size(scheme)
end
