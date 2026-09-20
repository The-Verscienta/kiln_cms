defmodule KilnCMS.CMS.PreviewToken do
  @moduledoc """
  Signed, short-lived tokens for previewing **unpublished** content.

  An editor mints a token for a draft record of any content type; anyone holding
  the token can fetch that one record (bypassing the published-only read policy)
  until it expires. Tokens are signed with `Phoenix.Token` — stateless and
  tamper-proof, no DB storage.

  A token is **read-only** (it is only ever redeemed by `GET /preview/:token`,
  the shared view at `/preview/:token/live`, and the visual-editing bridge's
  annotated read and live socket — `KilnCMSWeb.VisualEditingController`,
  `KilnCMSWeb.BridgeSocket`), **per-document** (it names one
  record and the site that owns it) and **short-lived** (15 minutes). That makes
  it the credential to hand a browser in place of an API key: a leaked link
  exposes one draft, briefly, and nothing else.

  ## Minting

  `mint/3` is the only way a token is issued on a request path — the content
  editor's *Copy preview link* action and `POST /api/content/:type/:id/preview-token`
  both go through it. `sign/1` is the unchecked primitive underneath.

  A token is **read-only** (it is only ever redeemed by `GET /preview/:token`
  and the shared view at `/preview/:token/live`), **per-document** (it names one
  record and the site that owns it) and **short-lived** (15 minutes). That makes
  it the credential to hand a browser in place of an API key: a leaked link
  exposes one draft, briefly, and nothing else.

  ## Minting

  `mint/3` is the only way a token is issued on a request path — the content
  editor's *Copy preview link* action and `POST /api/content/:type/:id/preview-token`
  both go through it. `sign/1` is the unchecked primitive underneath.
  """
  alias KilnCMS.CMS.Checks.ReadableContentType
  alias KilnCMS.CMS.ContentTypes

  @salt "content preview"
  # Short window: a preview link is meant for an immediate review, so a leaked
  # link only exposes draft content briefly (was 1h).
  @max_age_seconds 900

  @typedoc "What `mint/3` returns: the token, where to open it, and when it lapses."
  @type minted :: %{
          token: String.t(),
          url: String.t(),
          type: String.t(),
          id: String.t(),
          expires_at: DateTime.t()
        }

  @doc "How long a preview token stays valid, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc """
  Mint a preview token for the `type` document `id`, on behalf of `actor`.

  Options: `:actor` (required, `nil` is refused) and `:tenant` (the org the
  request is served for — the token is bound to it).

  The gate is **editorial read visibility** — the grant that lets an editor see
  a draft at all (`KilnCMS.CMS.Checks.ReadableContentType`; admins included) —
  not merely "can read this record". The difference is a published document:
  anyone may read its live row, but the preview renders the row's pending
  working copy (`KilnCMS.CMS.WorkingCopy`), which only editors see. A token is
  a way to *distribute* what the minter can already see, so it may carry no
  more than that.

  Returns `{:error, :not_found}` for an unknown type, a missing record, or one
  the actor cannot read at all (existence is not confirmed), and
  `{:error, :forbidden}` when the actor can read the record but not as an
  editor.
  """
  @spec mint(atom() | String.t(), String.t(), keyword()) ::
          {:ok, minted()} | {:error, :not_found | :forbidden}
  def mint(type, id, opts) do
    actor = Keyword.get(opts, :actor)
    org_id = KilnCMS.Accounts.org_id(Keyword.fetch!(opts, :tenant))

    with false <- is_nil(actor),
         %{} = ct <- ContentTypes.get(type, org_id),
         {:ok, record} <- ContentTypes.get_record(ct, id, actor: actor, tenant: org_id),
         {:editor?, true} <- {:editor?, editorial_read?(actor, record, org_id)} do
      token = sign(record)

      {:ok,
       %{
         token: token,
         url: url(token, org_id),
         type: to_string(ct.type),
         id: record.id,
         expires_at: DateTime.add(DateTime.utc_now(), @max_age_seconds, :second)
       }}
    else
      {:editor?, false} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Whether `actor` may mint a preview token for `record` — the check `mint/3`
  applies, for a caller that already holds the record and only needs to decide
  whether to offer the action (the content editor's button).
  """
  @spec mintable?(struct(), term()) :: boolean()
  def mintable?(%{org_id: org_id} = record, actor) when not is_nil(actor),
    do: editorial_read?(actor, record, org_id)

  def mintable?(_record, _actor), do: false

  # The editors-see-everything grant of the content read policy, asked directly:
  # the same check, so the button, the API and the policy cannot disagree about
  # who sees drafts. The subject only has to carry the tenant — that is all
  # `Scoping` reads off it to resolve the actor's tier on this site.
  defp editorial_read?(actor, %resource{}, org_id) do
    ReadableContentType.match?(actor, %{resource: resource, subject: %{tenant: org_id}}, [])
  end

  @doc """
  The shareable link for `token`, on the site that owns it.

  Built from the org's own base URL rather than the endpoint's: a token is only
  honoured on the host of the site it names, so a link to any other host is a
  dead link.
  """
  @spec url(String.t(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: String.t()
  def url(token, org), do: KilnCMSWeb.Tenant.base_url(org) <> "/preview/" <> token

  @doc """
  Sign a preview token for a content record (any content type) — **unchecked**.
  Request paths mint through `mint/3`, which decides whether the caller may.

  The token carries the record's `org_id` alongside `{type, id}` (#1309): the
  preview read runs `authorize?: false`, so the tenant in the token is what
  scopes it — content resources are org-scoped and a tenant-less read is
  refused under strict tenancy. The type is the public type *name*, so an
  admin-defined type (every one of which is stored as a `KilnCMS.CMS.Entry`)
  names itself rather than the shared tier.
  """
  @spec sign(struct()) :: String.t()
  def sign(%{id: id, org_id: org_id} = record) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{
      type: ContentTypes.type_name_for(record),
      id: id,
      org_id: org_id
    })
  end

  @doc """
  Verify a preview token, returning `{:ok, %{type: type, id: id, org_id: org_id}}`
  (the type as its public name, resolved against `org_id`) or an error
  (`:invalid` / `:expired`). A token minted before the org was part of the
  payload is `:invalid` — nothing may read tenant-less on its behalf.
  """
  @spec verify(String.t()) ::
          {:ok, %{type: String.t(), id: String.t(), org_id: String.t()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, %{type: type, id: _, org_id: org_id} = claims}
      when is_binary(org_id) and is_binary(type) ->
        {:ok, claims}

      # No tenant (pre-#1309), or a type atom — the shape before a dynamic
      # type could name itself. Either way nothing to resolve it against.
      {:ok, _legacy} ->
        {:error, :invalid}

      error ->
        error
    end
  end

  def verify(_), do: {:error, :invalid}
end
