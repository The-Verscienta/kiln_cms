defmodule KilnCMS.CMS.PreviewToken do
  @moduledoc """
  Signed, short-lived tokens for previewing **unpublished** content.

  An editor mints a token for a draft record of any content type; anyone holding
  the token can fetch that one record (bypassing the published-only read policy)
  until it expires. Tokens are signed with `Phoenix.Token` — stateless and
  tamper-proof, no DB storage.
  """
  @salt "content preview"
  # Short window: a preview link is meant for an immediate review, so a leaked
  # link only exposes draft content briefly (was 1h).
  @max_age_seconds 900

  @doc "Mint a preview token for a content record (any content type)."
  @spec sign(struct()) :: String.t()
  def sign(%resource{id: id}) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{type: type_for(resource), id: id})
  end

  @doc """
  Verify a preview token, returning `{:ok, %{type: type, id: id}}` or an error
  (`:invalid` / `:expired`).
  """
  @spec verify(String.t()) :: {:ok, %{type: atom(), id: String.t()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds)
  end

  def verify(_), do: {:error, :invalid}

  # Derive the content type atom from the resource module
  # (`KilnCMS.CMS.Page` -> `:page`), so any content type can be previewed.
  defp type_for(resource),
    do:
      resource |> Module.split() |> List.last() |> Macro.underscore() |> String.to_existing_atom()
end
