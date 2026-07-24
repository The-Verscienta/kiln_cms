defmodule KilnCMS.CMS.Changes.RecordSlugRedirect do
  @moduledoc """
  When a **published** record's canonical public path changes — a slug rename,
  or a `path_alias` (#485) added, changed, or removed — records a 301 redirect
  from the vacated path to the record (in the same transaction), so inbound
  links and SEO equity survive URL changes. Draft changes record nothing —
  their URLs were never public.

  Also drops any stale redirect occupying the record's *new* path: real
  content always wins over a redirect in delivery, but the row would
  resurface if the record moved on again.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Slugs

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.data.state == :published and path_changing?(changeset) do
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        record_redirect(changeset.data, record)
        {:ok, record}
      end)
    else
      changeset
    end
  end

  defp path_changing?(changeset) do
    is_binary(changeset.data.slug) and changeset.data.slug != "" and
      (Ash.Changeset.changing_attribute?(changeset, :slug) or
         Ash.Changeset.changing_attribute?(changeset, :path_alias))
  end

  defp record_redirect(data, record) do
    with ct when not is_nil(ct) <- Slugs.descriptor_for_record(record) do
      old_path = Slugs.public_path_for(ct, data)
      new_path = Slugs.public_path_for(ct, record)
      opts = [authorize?: false, tenant: Map.get(record, :org_id)]

      if old_path != new_path do
        CMS.create_redirect!(
          %{
            path: old_path,
            locale: record.locale,
            target_type: to_string(ct.type),
            target_id: record.id
          },
          opts
        )

        # The new path is live content again — retire any redirect squatting on it.
        [query: [filter: [path: new_path, locale: record.locale]]]
        |> Keyword.merge(opts)
        |> CMS.list_redirects!()
        |> Enum.each(&CMS.destroy_redirect!(&1, opts))
      end
    end

    :ok
  end
end
