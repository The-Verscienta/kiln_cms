defmodule KilnCMS.CMS.PreviewToken do
  @moduledoc """
  Signed, short-lived tokens for previewing **unpublished** content.

  An editor mints a token for a draft Page/Post; anyone holding the token can
  fetch that one record (bypassing the published-only read policy) until it
  expires. Tokens are signed with `Phoenix.Token` — stateless and tamper-proof,
  no DB storage.
  """
  alias KilnCMS.CMS.{Page, Post}

  @salt "content preview"
  @max_age_seconds 3600

  @doc "Mint a preview token for a Page or Post record."
  @spec sign(Page.t() | Post.t()) :: String.t()
  def sign(%resource{id: id}) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{type: type_for(resource), id: id})
  end

  @doc """
  Verify a preview token, returning `{:ok, %{type: :page | :post, id: id}}` or
  an error (`:invalid` / `:expired`).
  """
  @spec verify(String.t()) :: {:ok, %{type: :page | :post, id: String.t()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds)
  end

  def verify(_), do: {:error, :invalid}

  defp type_for(Page), do: :page
  defp type_for(Post), do: :post
end
