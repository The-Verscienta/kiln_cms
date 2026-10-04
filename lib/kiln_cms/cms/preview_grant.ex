defmodule KilnCMS.CMS.PreviewGrant do
  @moduledoc """
  A verified preview token, held as a **read grant for one record**.

  `KilnCMSWeb.Plugs.PreviewGrant` builds one from a `KilnCMS.CMS.PreviewToken`
  presented on a headless read (`x-kiln-preview-token`, or `?preview_token=`)
  and puts it in the request's Ash context under `shared`, so it rides into the
  JSON:API read and every relationship load under it. The content read policy
  then admits exactly that row (`KilnCMS.CMS.Checks.PreviewGrant`), and
  `KilnCMS.CMS.Checks.LinkEndsReadable` treats it as a readable link end. That
  is how a front end renders a draft in its own templates with the same calls
  it makes for a published page — nothing is read with `authorize?: false`.

  Checks match on this **struct**, never on a bare map: no request input can
  set Ash context, and a struct cannot be spelled in a query string, so a
  client cannot hand itself a grant without a token that verifies.
  """

  @enforce_keys [:type, :id, :org_id, :resource]
  defstruct [:type, :id, :org_id, :resource]

  @typedoc """
  `type` is the public type name the token carries, `id` the record, `org_id`
  the site that owns it, and `resource` the Ash resource the record lives in
  (`KilnCMS.CMS.Entry` for an admin-defined type).
  """
  @type t :: %__MODULE__{
          type: String.t(),
          id: String.t(),
          org_id: String.t(),
          resource: module()
        }

  @context_key :kiln_preview_grant

  @doc "The Ash context that carries `grant` into a read and its relationship loads."
  @spec context(t()) :: map()
  def context(%__MODULE__{} = grant), do: %{shared: %{@context_key => grant}}

  @doc "The grant in an Ash context map, or nil."
  @spec from_context(map() | nil) :: t() | nil
  def from_context(%{shared: %{@context_key => %__MODULE__{} = grant}}), do: grant
  def from_context(_context), do: nil
end
