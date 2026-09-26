defmodule KilnCMS.CMS.Validations.AiBaseUrl do
  @moduledoc """
  A site's OpenAI-compatible endpoint (`KilnCMS.CMS.SiteAiProvider.base_url`)
  has to be an `https://` URL that the SSRF rules allow.

  A site admin is not the operator. The URL is a connection this server opens
  with the site's API key and content in the request, and the error that comes
  back is shown to them. So a private, loopback, link-local or metadata address
  is refused here, where the admin can see why. It is checked again, and the
  address pinned, on every request (`KilnCMS.SafeFetch`), because DNS can
  change between the save and the call.

  `https://` is required whatever `KilnCMS.Webhooks.SafeUrl`'s own
  `require_https` says: the request carries an API key, and a plain-HTTP one
  hands it to every hop on the way. An operator whose model server is on the
  private network sets `ASSIST_MODEL` and friends, which are trusted and
  unchecked.

  No query string or fragment: the path `/chat/completions` is appended to it,
  and a query would put whatever it holds in every request's URL.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      url when is_binary(url) and url != "" -> check(url)
      _blank -> :ok
    end
  end

  @doc false
  # Shared with `KilnCMS.LLM.Client`, so a row written before a rule
  # tightened is refused at call time by the same words.
  @spec check(String.t()) :: :ok | {:error, Exception.t()}
  def check(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        case KilnCMS.Webhooks.SafeUrl.validate(url) do
          :ok -> :ok
          {:error, message} -> error(message)
        end

      %URI{scheme: "https"} ->
        error("must be an https:// URL with a host and no query, fragment or credentials")

      _other ->
        error("must start with https://")
    end
  end

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :base_url, message: message)}
end
