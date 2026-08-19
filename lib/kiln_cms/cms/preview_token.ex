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

  @doc """
  Mint a preview token for a content record (any content type).

  The token carries the record's `org_id` alongside `{type, id}` (#1309): the
  preview read runs `authorize?: false`, so the tenant in the token is what
  scopes it — content resources are org-scoped and a tenant-less read is
  refused under strict tenancy.
  """
  @spec sign(struct()) :: String.t()
  def sign(%resource{id: id, org_id: org_id}) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{
      type: type_for(resource),
      id: id,
      org_id: org_id
    })
  end

  @doc """
  Verify a preview token, returning `{:ok, %{type: type, id: id, org_id: org_id}}`
  or an error (`:invalid` / `:expired`). A token minted before the org was part
  of the payload is `:invalid` — nothing may read tenant-less on its behalf.
  """
  @spec verify(String.t()) ::
          {:ok, %{type: atom(), id: String.t(), org_id: String.t()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, %{type: _, id: _, org_id: org_id} = claims} when is_binary(org_id) -> {:ok, claims}
      {:ok, _legacy} -> {:error, :invalid}
      error -> error
    end
  end

  def verify(_), do: {:error, :invalid}

  # Derive the content type atom from the resource module
  # (`KilnCMS.CMS.Page` -> `:page`), so any content type can be previewed.
  defp type_for(resource),
    do:
      resource |> Module.split() |> List.last() |> Macro.underscore() |> String.to_existing_atom()
end
