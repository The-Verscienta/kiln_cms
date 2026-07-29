defmodule KilnCMS.CMS.Validations.BrandTokens do
  @moduledoc """
  Validates the white-label branding tokens (#48).

  ## Image URLs

  `logo_url` / `favicon_url` / `social_image_url` follow the same rule as the
  SEO URLs — a same-origin relative path or an absolute `https://` URL — via
  `KilnCMS.CMS.Validations.SeoUrls.valid?/1`, so `javascript:`, `data:`, plain
  `http:` and protocol-relative `//host` are rejected in one place for both
  features.

  Branding narrows it further: the host must be one the CSP `img-src` actually
  allows (`'self'`, the configured `:csp_img_src` hosts, or the media storage
  host). An off-origin logo would otherwise validate happily and then be
  silently blocked by the browser — a blank logo in production instead of an
  error in the settings form. The CSP is deliberately NOT widened from this
  value: a per-org row must never flow into a global, cross-tenant response
  header. Operators extend it with `CSP_IMG_SRC`.

  ## Brand colour

  A hard allowlist: `#rgb` or `#rrggbb`, nothing else.

  The value is interpolated into a `<style>` block on every rendered page
  (`KilnCMSWeb.Layouts.brand_tokens/1`), and `style-src` carries
  `'unsafe-inline'` because inline `style=` attributes can't take a nonce. An
  unvalidated value there is arbitrary CSS, not merely a bad colour:
  `#fff; position: fixed; inset: 0; z-index: 9999; background: #000` defaces
  every page on the site, `}` breaks out of the rule into arbitrary selectors,
  and attribute-selector + `url()` tricks are a classic CSS exfiltration
  primitive. An org admin is not the platform operator, so this input is
  untrusted.

  Hex-only is deliberate. `<input type="color">` emits exactly `#rrggbb`, and
  `KilnCMS.Branding.Color` re-derives every emitted token from the parsed
  channels anyway — so no user-supplied byte ever reaches the stylesheet.
  Accepting `oklch()` / `color-mix()` / `var()` would each need their own
  sub-grammar for no operator benefit. Alpha is rejected: a translucent brand
  colour silently breaks the contrast pairing with `--color-primary-content`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Validations.SeoUrls

  @url_fields [:logo_url, :favicon_url, :social_image_url]

  @hex ~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_urls(changeset) do
      validate_color(Ash.Changeset.get_attribute(changeset, :brand_color))
    end
  end

  defp validate_urls(changeset) do
    Enum.reduce_while(@url_fields, :ok, fn field, _acc ->
      case validate_url(field, Ash.Changeset.get_attribute(changeset, field)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_url(_field, value) when value in [nil, ""], do: :ok

  defp validate_url(field, value) when is_binary(value) do
    cond do
      not SeoUrls.valid?(value) ->
        {:error,
         InvalidAttribute.exception(
           field: field,
           message: "must be a relative path or an absolute https:// URL",
           value: value
         )}

      not allowed_host?(value) ->
        {:error,
         InvalidAttribute.exception(
           field: field,
           message:
             "host is not allowed by the site's image policy — upload the image to the " <>
               "media library, or ask an operator to add the host to CSP_IMG_SRC",
           value: value
         )}

      true ->
        :ok
    end
  end

  defp validate_url(field, value), do: validate_url(field, to_string(value))

  # A relative path is same-origin and always fine. An absolute URL must be on a
  # host the CSP `img-src` already permits, otherwise the browser blocks it.
  defp allowed_host?(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: nil} -> true
      %URI{host: host} -> host in allowed_hosts()
    end
  end

  defp allowed_hosts do
    configured =
      :kiln_cms
      |> Application.get_env(:csp_img_src, [])
      |> Enum.map(&host_of/1)

    [endpoint_host(), storage_host() | configured]
    |> Enum.reject(&is_nil/1)
  end

  defp endpoint_host do
    :kiln_cms
    |> Application.get_env(KilnCMSWeb.Endpoint, [])
    |> get_in([:url, :host])
  end

  # Derived from the storage adapter so this is automatically correct on both
  # the Local adapter (relative `/uploads/...`, no host) and S3 (off-origin,
  # which operators must already have in CSP_IMG_SRC for media to render).
  defp storage_host do
    host_of(KilnCMS.Storage.url("_"))
  rescue
    _ -> nil
  end

  defp host_of(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      # A bare `csp_img_src` entry like "cdn.example.com" parses as a path.
      _ -> value |> String.trim() |> String.split("/") |> List.first() |> presence()
    end
  end

  defp host_of(_), do: nil

  defp presence(""), do: nil
  defp presence(value), do: value

  defp validate_color(value) when value in [nil, ""], do: :ok

  defp validate_color(value) when is_binary(value) do
    if Regex.match?(@hex, String.trim(value)) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :brand_color,
         message: "must be a hex colour like #1d4ed8",
         value: value
       )}
    end
  end

  defp validate_color(value), do: validate_color(to_string(value))

  @doc """
  Canonical lowercase `#rrggbb` for an accepted colour, or `nil`.

  Shared with `KilnCMS.Branding` so the config layer (`BRAND_PRIMARY_COLOR`) is
  held to the same grammar as the database column — one grammar end to end, so
  an environment variable can't become the injection vector the column isn't.
  """
  @spec normalize_color(term()) :: String.t() | nil
  def normalize_color(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      not Regex.match?(@hex, trimmed) -> nil
      byte_size(trimmed) == 7 -> String.downcase(trimmed)
      true -> expand_shorthand(trimmed)
    end
  end

  def normalize_color(_), do: nil

  defp expand_shorthand("#" <> <<r::binary-1, g::binary-1, b::binary-1>>) do
    String.downcase("##{r}#{r}#{g}#{g}#{b}#{b}")
  end
end
