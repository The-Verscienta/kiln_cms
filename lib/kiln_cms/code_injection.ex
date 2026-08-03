defmodule KilnCMS.CodeInjection do
  @moduledoc """
  Resolved per-site code injection for the delivery site (#490).

  The read API over `KilnCMS.CMS.SiteCodeInjection`, and the one place that
  decides what the delivery layout emits and what the delivery CSP allows.
  Nothing outside this module should read that resource directly.

  ## Performance contract

  `for_org/1` is on the **public delivery hot path** — once per request — and
  behaves like `KilnCMS.Branding.for_org/1` for the same reasons:

    * it caches the **resolved struct**, never the row, because most sites have
      no row and `KilnCMS.Cache.fetch/3` never caches a `nil`;
    * it **never writes**, so an anonymous `GET` cannot become an `INSERT`.

  ## Why the CSP additions live here

  Delivery serves `script-src 'self' 'nonce-…'`. A pasted vendor snippet does
  nothing under that: an external `<script src>` fails on origin, an inline one
  on the missing nonce. So the same struct that carries the HTML carries the
  sources that make it run, and `KilnCMSWeb.Plugs.CodeInjection` applies both
  together. Splitting them would let a site be configured into a state where the
  snippet is saved, visible in the settings form, and silently inert.

  ### Hashes, not nonces

  Inline scripts are authorized by `'sha256-…'` over their exact body, computed
  once at save time. A nonce is per-request, so it cannot exist in a statically
  exported artifact — and static export is one of the surfaces this covers. A
  hash is a property of the snippet, so the same policy is correct whether the
  page was rendered live or written to disk an hour ago.

  The extraction is deliberately literal about what a browser hashes: the bytes
  between `<script …>` and the first `</script`, with no entity decoding and no
  re-serialization. That is also how the HTML tokenizer treats script raw text,
  which is why a targeted scan is *more* faithful here than round-tripping the
  snippet through a parser would be.
  """
  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  require Logger

  defstruct head_html: nil,
            footer_html: nil,
            script_src: [],
            connect_src: [],
            img_src: [],
            script_hashes: []

  @type t :: %__MODULE__{
          head_html: String.t() | nil,
          footer_html: String.t() | nil,
          script_src: [String.t()],
          connect_src: [String.t()],
          img_src: [String.t()],
          script_hashes: [String.t()]
        }

  # Matches `KilnCMS.Branding`'s TTL: the cache is in-BEAM only, so this also
  # bounds staleness on other nodes after a save. The writing node is busted
  # precisely by `Changes.BustCodeInjection`.
  @ttl :timer.minutes(5)

  @doc """
  The resolved injection for an org — an `%Organization{}`, a bare org id, or
  `nil` (the default org).

  Always returns a struct. An unconfigured site, a disabled one, and a
  transient read failure all produce the empty struct, which emits nothing and
  adds nothing to the CSP.
  """
  @spec for_org(Accounts.Organization.t() | Ash.UUID.t() | nil) :: t()
  def for_org(%Accounts.Organization{id: id}), do: for_org(id)
  def for_org(nil), do: for_org(Accounts.default_org_id())

  def for_org(org_id) when is_binary(org_id) do
    KilnCMS.Cache.fetch(KilnCMS.Cache.code_injection_key(org_id), @ttl, fn ->
      resolve(org_id)
    end) || empty()
  end

  def for_org(_), do: empty()

  @doc "The struct an unconfigured, disabled, or unreadable site resolves to."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Whether this site injects anything at all (the layout skips the markup entirely)."
  @spec any?(t()) :: boolean()
  def any?(%__MODULE__{head_html: nil, footer_html: nil}), do: false
  def any?(%__MODULE__{head_html: "", footer_html: ""}), do: false
  def any?(%__MODULE__{}), do: true

  @doc """
  The CSP source lists this site adds, as `%{script_src:, connect_src:, img_src:}`.

  Empty lists for an unconfigured or disabled site, which is what keeps the
  stock policy byte-identical for every site that does not use the feature.
  """
  @spec csp_sources(t()) :: %{
          script_src: [String.t()],
          connect_src: [String.t()],
          img_src: [String.t()]
        }
  def csp_sources(%__MODULE__{} = injection) do
    %{
      script_src: injection.script_src ++ Enum.map(injection.script_hashes, &"'sha256-#{&1}'"),
      connect_src: injection.connect_src,
      img_src: injection.img_src
    }
  end

  @doc """
  Base64 SHA-256 of every inline `<script>` body across the given HTML fragments.

  What a browser hashes for a CSP `'sha256-…'` source is the element's raw text
  content, byte for byte, before any entity decoding. So this takes the bytes
  between the `>` that ends the start tag and the first `</script`, exactly as
  the HTML tokenizer's script-data state does.

  A `<script src=…>` element has no body to hash; an empty or whitespace-only
  body is skipped too, since a browser will not execute it and a `'sha256-…'`
  for it would only widen the policy.
  """
  @spec inline_hashes([String.t() | nil]) :: [String.t()]
  def inline_hashes(fragments) do
    fragments
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.flat_map(&inline_bodies/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&Base.encode64(:crypto.hash(:sha256, &1)))
    |> Enum.uniq()
  end

  # `<script` … `>` … body … `</script`. Case-insensitive on the tag names,
  # since HTML is, and non-greedy on the start tag so an attribute value
  # containing `>` cannot swallow the body.
  @script_open ~r/<script\b[^>]*>/i
  @script_close ~r/<\/script/i
  @comment ~r/<!--.*?-->/s

  # `type` values a browser executes as script. Anything else — a JSON island, a
  # client-side template — is data the browser never runs, so hashing it would
  # put a `'sha256-…'` into the CSP of every page of the site authorizing a body
  # that is not executing anywhere. That matters beyond this feature: a hash in
  # the header is a standing permission, so it turns any OTHER HTML-injection
  # sink on a delivery page into script execution against a nonce-only policy.
  @executable_types ~w(
    module text/javascript application/javascript application/ecmascript
    text/ecmascript application/x-javascript text/jscript
  )

  defp inline_bodies(html) do
    # Comments first: a `<script>` inside one is inert in the document, and
    # hashing it is the same standing-permission problem as a JSON island.
    html |> String.replace(@comment, "") |> inline_bodies([])
  end

  defp inline_bodies(html, acc) do
    case Regex.run(@script_open, html, return: :index) do
      nil ->
        Enum.reverse(acc)

      [{start, length}] ->
        start_tag = binary_part(html, start, length)
        rest = binary_part(html, start + length, byte_size(html) - start - length)

        case Regex.run(@script_close, rest, return: :index) do
          # An unclosed `<script>` runs to end-of-fragment in a browser too, so
          # the whole remainder is the body — and then there is nothing left to
          # scan.
          nil -> Enum.reverse(collect(start_tag, rest, acc))
          [{body_length, _}] -> continue(start_tag, rest, body_length, acc)
        end
    end
  end

  defp continue(start_tag, rest, body_length, acc) do
    body = binary_part(rest, 0, body_length)
    remainder = binary_part(rest, body_length, byte_size(rest) - body_length)
    inline_bodies(remainder, collect(start_tag, body, acc))
  end

  # Only bodies a browser will actually execute.
  defp collect(start_tag, body, acc) do
    if executable?(start_tag), do: [body | acc], else: acc
  end

  # One capture, quotes included, unquoted afterwards. Three alternation groups
  # would be ambiguous: Elixir returns a non-participating group as `""`, which
  # is indistinguishable from `type=""` — a legitimately empty value that means
  # "executable". Capturing the raw token instead keeps that distinction.
  @type_attr ~r/\btype\s*=\s*(?<value>"[^"]*"|'[^']*'|[^\s"'>]+)/i

  defp executable?(start_tag) do
    case Regex.named_captures(@type_attr, start_tag) do
      nil -> true
      %{"value" => value} -> value |> unquote_attr() |> executable_type?()
    end
  end

  defp unquote_attr(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_attr(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp unquote_attr(value), do: value

  # An empty `type` is the same as none. Parameters after `;` (a charset) are
  # ignored, matching how a browser reads the attribute.
  defp executable_type?(nil), do: true

  defp executable_type?(type) do
    type
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> true
      normalized -> normalized in @executable_types
    end
  end

  defp resolve(org_id) do
    case row(org_id) do
      :error -> nil
      nil -> empty()
      %{enabled: false} -> empty()
      row -> build(row)
    end
  end

  defp build(row) do
    %__MODULE__{
      head_html: blank_to_nil(row.head_html),
      footer_html: blank_to_nil(row.footer_html),
      script_src: row.script_src || [],
      connect_src: row.connect_src || [],
      img_src: row.img_src || [],
      script_hashes: row.script_hashes || []
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  # `:error` (not nil) on an infrastructure failure, so `resolve/1` can decline
  # to cache it — a transient fault degrades to "no injection" for one request
  # rather than for the whole TTL.
  defp row(org_id) do
    case CMS.list_site_code_injection(authorize?: false, tenant: org_id) do
      {:ok, [row | _]} -> row
      {:ok, []} -> nil
      {:error, reason} -> log_error(reason)
    end
  rescue
    error -> log_error(error)
  end

  defp log_error(reason) do
    Logger.warning("Code injection unreadable, serving none: #{inspect(reason)}")
    :error
  end
end
