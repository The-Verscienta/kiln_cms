defmodule KilnCMS.CMS.ReleasePreview do
  @moduledoc """
  Preview a content release as if it were already live (#500, phase 2).

  The issue frames this on `KilnCMS.Firing.PointInTime` — "the same overlay idea,
  future-facing instead of past-facing" — and the *idea* is exactly that. The
  machinery, though, is much smaller than the past-facing case, and deliberately
  so: point-in-time has to reconstruct a document from `:changes_only` version
  history because the state it wants no longer exists anywhere. A release's
  future state is not lost, it is **the live draft row** — in Kiln a document's
  editable record *is* its next published state, with the fired artifact as the
  frozen public copy alongside it. So the overlay is a read, not a replay.

  What the overlay produces, per item:

    * `:publish` — the record as it stands, which is precisely what go-live will
      publish. Rendered with the same block components the shared draft preview
      (`KilnCMSWeb.TokenPreviewLive`) uses, so preview and delivery agree.
    * `:unpublish` — the record that will come *off* the site, shown as such.
      There is nothing to render for the after state; the point is knowing what
      disappears.

  ## Sharing

  Signed with `Phoenix.Token` and stateless, exactly like
  `KilnCMS.CMS.PreviewToken`. The window is wider than that module's 15 minutes
  and the reason is the use case, not carelessness: a single-record preview is
  an immediate "look at this", while a release preview is a sign-off pass over
  N documents that has to survive a meeting. One hour is the same window content
  preview itself used before #379 narrowed it, and a fresh link is one click
  away when it lapses.

  The token names the release **and** its org, and both are checked against the
  site the link is opened on. A preview served under another tenant's branding
  would misattribute unpublished content to a site that doesn't own it.
  """
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  @salt "content release preview"
  @max_age_seconds 3600

  @doc "How long a shared release-preview link stays valid, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc "Mint a shareable preview token for a release."
  @spec sign(struct()) :: String.t()
  def sign(%{id: id, org_id: org_id}) do
    Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{release_id: id, org_id: org_id})
  end

  @doc """
  Verify a release-preview token, returning `{:ok, %{release_id:, org_id:}}` or
  an error (`:invalid` / `:expired`).
  """
  @spec verify(String.t()) ::
          {:ok, %{release_id: String.t(), org_id: String.t()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age_seconds)
  end

  def verify(_token), do: {:error, :invalid}

  @typedoc """
  One document in the overlay: the release item, the content record it points at
  (`nil` when the record is gone), and its resolved type descriptor.
  """
  @type entry :: %{
          item: struct(),
          record: struct() | nil,
          label: String.t(),
          title: String.t()
        }

  @doc """
  The release's pending items with their content resolved, in the order they
  were added.

  Items whose record has since been deleted are kept with `record: nil` rather
  than dropped — "this is in the release and no longer exists" is exactly what a
  reviewer needs to see before go-live, and silently omitting it would make the
  preview claim a release is fine when it would abort.
  """
  @spec overlay(struct(), keyword()) :: [entry()]
  def overlay(release, opts \\ []) do
    opts = Keyword.merge([authorize?: false, tenant: release.org_id], opts)

    release.id
    |> CMS.list_release_items_with_status!(:pending, opts)
    |> Enum.map(&resolve(&1, opts))
  end

  defp resolve(item, opts) do
    {record, label} = fetch(item, opts)

    %{
      item: item,
      record: record,
      label: label,
      title: (record && record.title) || item.content_type
    }
  end

  defp fetch(item, opts) do
    label = type_label(item.content_type, opts)

    case ContentTypes.get_record(item.content_type, item.content_id, opts) do
      {:ok, record} -> {record, label}
      _ -> {nil, label}
    end
  rescue
    # A dynamic type retired since the item was added: no descriptor, no record.
    _error -> {nil, item.content_type}
  end

  defp type_label(content_type, opts) do
    case ContentTypes.get(content_type, Keyword.get(opts, :tenant)) do
      %{label: label} -> label
      _ -> content_type
    end
  end
end
