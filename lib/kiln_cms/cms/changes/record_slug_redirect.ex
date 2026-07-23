defmodule KilnCMS.CMS.Changes.RecordSlugRedirect do
  @moduledoc """
  When a **published** record's slug changes, records a 301 redirect from the
  vacated public path to the record (in the same transaction as the rename),
  so inbound links and SEO equity survive URL changes. Draft renames record
  nothing — their URLs were never public.

  Also drops any stale redirect occupying the record's *new* path: real
  content always wins over a redirect in delivery, but the row would
  resurface if the record moved on again.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Slugs

  @impl true
  def change(changeset, _opts, _context) do
    old_slug = changeset.data.slug

    if changeset.data.state == :published and is_binary(old_slug) and old_slug != "" and
         Ash.Changeset.changing_attribute?(changeset, :slug) do
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        record_redirect(old_slug, record)
        {:ok, record}
      end)
    else
      changeset
    end
  end

  defp record_redirect(old_slug, record) do
    with ct when not is_nil(ct) <- Slugs.descriptor_for_record(record) do
      old_path = Slugs.public_path(ct, old_slug)
      new_path = Slugs.public_path(ct, record.slug)
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
