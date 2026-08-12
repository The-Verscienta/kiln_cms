# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule KilnCMS.CMS.Changes.BustTypeRegistry do
  @moduledoc """
  Invalidates the cached dynamic-type registry (and the sitemap, whose URL set
  depends on which types exist) after any `TypeDefinition` write — create,
  update (incl. restore), or archive.

  Also runs on `FieldDefinition` writes (#480). It is a field, not a type, that
  decides whether a type is event-shaped and so has an `.ics` calendar, so the
  cached answer to that question has to drop when a `datetime_range` field is
  added or removed — otherwise a new event type has no calendar until a TTL
  passes, with nothing to explain why.

  Published payloads of an archived type may linger under their own
  `{name, slug}` cache keys until their short TTL passes; `get_by_path/2`
  stops resolving the type immediately, so only already-cached responses ride
  out the window.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, record ->
      # The type registry, sitemap and llms.txt are all per-org (#336): bust the
      # writing type's own site so its editors/delivery see the change at once
      # (another org's cached registry is unaffected).
      KilnCMS.Cache.bust_type_registry(record.org_id)
      KilnCMS.Cache.bust_sitemap(record.org_id)
      KilnCMS.Cache.bust_llms(record.org_id)
      {:ok, record}
    end)
    |> Ash.Changeset.after_transaction(&bust_feeds/2)
    |> Ash.Changeset.after_transaction(&enqueue_seo_refire/2)
  end

  # Re-fire every published document of a type whose SEO pattern changed (#1135).
  # Only when `seo_title_pattern` or `seo_description_pattern` actually changed,
  # after COMMIT (so a re-fire queued before COMMIT isn’t undone), and a failure
  # here never fails the type save. `FieldDefinition` name changes are handled
  # separately — `[field:<name>]` in a pattern resolves off custom_fields, so a
  # rename there also needs a re-fire, but only when the name itself changed.
  defp enqueue_seo_refire(changeset, {:ok, record} = result) do
    cond do
      # TypeDefinition — check the two pattern attributes
      Map.has_key?(record, :seo_title_pattern) or Map.has_key?(record, :seo_description_pattern) ->
        if Ash.Changeset.changing_attribute?(changeset, :seo_title_pattern) or
             Ash.Changeset.changing_attribute?(changeset, :seo_description_pattern) do
          KilnCMS.Firing.Sweep.sweep_type(record.org_id, record.name)
        end

        result

      # FieldDefinition — check if the field name changed (affects [field:<name>] tokens)
      Map.has_key?(record, :name) and
          (Map.has_key?(record, :content_type) or Map.has_key?(record, :type_definition_id)) ->
        if Ash.Changeset.changing_attribute?(changeset, :name) do
          # Determine which type this field belongs to and sweep it
          type =
            cond do
              not is_nil(Map.get(record, :type_definition_id)) ->
                # Dynamic type — look up its name via the definition id
                case KilnCMS.CMS.get_type_definition(record.type_definition_id,
                       authorize?: false,
                       tenant: record.org_id
                     ) do
                  {:ok, type_def} -> type_def.name
                  _ -> nil
                end

              content_type = Map.get(record, :content_type) ->
                to_string(content_type)

              true ->
                nil
            end

          if type, do: KilnCMS.Firing.Sweep.sweep_type(record.org_id, type)
        end

        result

      true ->
        result
    end
  rescue
    error ->
      require Logger
      Logger.warning("seo pattern re-fire enqueue failed: #{inspect(error)}")
      result
  end

  defp enqueue_seo_refire(_changeset, other), do: other

  # The feed *documents* (#719). `has_published_feed` is the other half of
  # `KilnCMS.Feeds.syndicated?/2`: turning it off stops `/recipes/feed.xml`
  # resolving at once, but the already-built site-wide feed kept listing recipe
  # entries until its TTL — and turning it on left the new type missing from
  # that feed for five minutes, with nothing on either page to explain why.
  #
  # After the transaction, not beside the busts above, for two reasons: a bust
  # that runs before COMMIT can be undone by a concurrent reader re-caching the
  # pre-write answer (see `BustFeedSettings`), and `bust_all_feeds/1` walks the
  # keyspace, which has no business happening with a Postgres transaction open.
  defp bust_feeds(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_all_feeds(record.org_id)
    result
  end

  defp bust_feeds(_changeset, other), do: other
end
