defmodule KilnCMS.CMS.Validations.SeoUrls do
  @moduledoc """
  Validates the SEO URL attributes (`canonical_url`, `seo_image`) on content
  writes. Both render into the public `<head>` and JSON-LD, so only same-origin
  relative paths or absolute `https://` URLs are accepted. Off-scheme values
  (`javascript:`, `data:`, plain `http:`, protocol-relative `//host`) are
  rejected so an editor can't point crawlers/social cards off-site.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @url_fields [:canonical_url, :seo_image]

  @impl true
  def validate(changeset, _opts, _context) do
    Enum.reduce_while(@url_fields, :ok, fn field, _acc ->
      case Ash.Changeset.get_attribute(changeset, field) do
        value when value in [nil, ""] ->
          {:cont, :ok}

        value when is_binary(value) ->
          if valid?(value),
            do: {:cont, :ok},
            else: {:halt, {:error, invalid(field, value)}}

        value ->
          {:halt, {:error, invalid(field, value)}}
      end
    end)
  end

  defp invalid(field, value) do
    InvalidAttribute.exception(
      field: field,
      message: "must be a relative path or an absolute https:// URL",
      value: value
    )
  end

  defp valid?(url) do
    url = String.trim(url)
    relative?(url) or https?(url)
  end

  defp relative?(url) do
    String.starts_with?(url, "/") and
      not String.starts_with?(url, "//") and
      not String.contains?(url, "..")
  end

  defp https?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end
end
