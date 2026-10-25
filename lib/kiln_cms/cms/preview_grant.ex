defmodule KilnCMS.CMS.PreviewGrant do
  @moduledoc """
  A verified preview token, as the content read policy sees it (#1887).

  `KilnCMS.CMS.PreviewToken` is the credential; this struct is what it unlocks
  once verified and pinned to the serving site: a read grant for **the one
  record it names**, on the plain headless reads (JSON:API, and the
  fired-artifact route rendering the working copy live). It reaches the policy
  in the Ash context under `:shared`, the one key Ash carries into the nested
  reads of the same request — the relationship loads behind `include=` and the
  both-ends re-read of `KilnCMS.CMS.Checks.LinkEndsReadable` — so a draft's
  edges to published documents come back with it.

  What it admits is decided by `KilnCMS.CMS.Checks.PreviewGrant`: the named id,
  on the primary `:read`, in the token's own site. Nothing else — not the
  published-only delivery actions, not search, not a write.
  """

  alias KilnCMS.CMS.PreviewToken

  @enforce_keys [:type, :id, :org_id]
  defstruct [:type, :id, :org_id]

  @type t :: %__MODULE__{type: String.t(), id: Ash.UUID.t(), org_id: Ash.UUID.t()}

  @doc """
  Verify `token` and pin it to `org_id`, the site the request is served for.

  `{:error, :invalid}` for a token that does not verify, has expired, or was
  minted on another site — a token is honoured only on the host of the site
  it names.
  """
  @spec verify(String.t() | nil, Ash.UUID.t() | nil) :: {:ok, t()} | {:error, :invalid}
  def verify(token, org_id) when is_binary(token) and is_binary(org_id) do
    case PreviewToken.verify(token) do
      {:ok, %{type: type, id: id, org_id: ^org_id}} ->
        {:ok, %__MODULE__{type: type, id: id, org_id: org_id}}

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_token, _org_id), do: {:error, :invalid}

  @doc """
  The Ash context that carries `grant` into a read and the reads nested in it:
  pass it as `context:` (or `Ash.PlugHelpers.set_context/2`).
  """
  @spec context(t() | nil) :: map()
  def context(nil), do: %{}
  def context(%__MODULE__{} = grant), do: %{shared: %{preview_grant: grant}}

  @doc """
  The grant an Ash context carries, if any. Takes the query's context, or the
  authorizer a policy check is handed (its `subject` is the query).
  """
  @spec from_context(term()) :: t() | nil
  def from_context(%{subject: %{context: context}}), do: from_context(context)
  def from_context(%{shared: %{preview_grant: %__MODULE__{} = grant}}), do: grant
  def from_context(_context), do: nil
end
