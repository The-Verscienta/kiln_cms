defmodule KilnCMS.Social.Validations.ProviderFields do
  @moduledoc """
  Each provider needs different identifying fields (#497), and the resource
  cannot express that with `allow_nil?` because the columns are shared.

    * Bluesky needs a `handle` — it is half of the credential pair.
    * Mastodon needs an `instance_url`, and it must be an absolute `https://`
      origin. Kiln makes server-side requests to whatever is in that column, so
      the validation is not cosmetic: without it the field accepts
      `http://169.254.169.254/…` and an admin form becomes an SSRF primitive.
      `KilnCMS.SafeFetch` is the second layer — it refuses the request at
      resolution time — but a value that can never work should not be storable.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    provider = Ash.Changeset.get_attribute(changeset, :provider)

    case provider do
      :bluesky -> require_present(changeset, :handle, "is required for Bluesky")
      :mastodon -> validate_instance_url(changeset)
      _other -> :ok
    end
  end

  defp require_present(changeset, field, message) do
    case changeset |> Ash.Changeset.get_attribute(field) |> blank?() do
      true -> {:error, field: field, message: message}
      false -> :ok
    end
  end

  defp validate_instance_url(changeset) do
    with :ok <- require_present(changeset, :instance_url, "is required for Mastodon"),
         url = Ash.Changeset.get_attribute(changeset, :instance_url),
         %URI{scheme: "https", host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, field: :instance_url, message: "must be an https:// URL"}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
