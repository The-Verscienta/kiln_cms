defmodule KilnCMS.CMS.Changes.StageWorkingFields do
  @moduledoc """
  Holds a live record's settings in its working copy (#1815,
  docs/working-copy.md): the `fields` argument of `:save_working_copy`.

  `fields` carries the held params — exactly the keys
  `KilnCMS.CMS.WorkingCopy.held_param_keys/1` names, in the shape the editor
  (or any caller) would send them to `:update`. They are judged by `:update`
  itself: a probe changeset is built for that action on the working view of
  the row, so every coercion and check an ordinary save gets runs here too —
  `ApplyCustomFields`, `DeriveSlug`, the slug, path-alias and URL validations,
  field grants, the tag merge verbs. The probe is never submitted. Its errors
  become this write's errors; its values are what the copy now holds.

  What is stored (`working_fields`) is only what **differs from the live
  row**: a field set back to its published value leaves the copy, and a copy
  whose text and fields all match the live row stops existing
  (`Changes.StampWorkingCopy`, declared after this). A key absent from `fields`
  keeps whatever the copy already held for it — absent means unchanged, never
  "clear".

  The live row is `changeset.data`; `:save_working_copy`'s `optimistic_lock`
  is what makes that trustworthy. Live relationship ids are re-read rather than
  taken from the struct, which may not have them loaded.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.fetch_argument(changeset, :fields) do
      {:ok, %{} = fields} when map_size(fields) > 0 -> stage(changeset, fields, context)
      _absent -> changeset
    end
  end

  defp stage(changeset, fields, context) do
    resource = changeset.resource
    live = changeset.data
    {held_params, unknown} = Map.split(stringify(fields), WorkingCopy.held_param_keys(resource))

    if map_size(unknown) > 0 do
      Ash.Changeset.add_error(changeset,
        field: :fields,
        message:
          "holds only content fields; save " <>
            (unknown |> Map.keys() |> Enum.sort() |> Enum.join(", ")) <> " through :update"
      )
    else
      probe =
        Ash.Changeset.for_update(
          WorkingCopy.view(live),
          :update,
          held_params,
          context |> Ash.Context.to_opts() |> Keyword.put(:tenant, live.org_id)
        )

      probe = check_slug_free(probe, live)

      if probe.valid? do
        held =
          WorkingCopy.held_fields(live)
          |> stage_attributes(resource, live, probe)
          |> stage_relationships(resource, live, probe, held_params)

        Ash.Changeset.force_change_attribute(changeset, :working_fields, held)
      else
        Ash.Changeset.add_error(changeset, probe.errors)
      end
    end
  end

  # The slug identity is a unique index, which only a submitted write meets —
  # and the probe is never submitted. A held address another record already
  # has would otherwise save cleanly and fail at "Publish changes" instead,
  # where a release would abort over it. `PromoteWorkingCopy`'s write meets the
  # index for real, for an address claimed between the save and the publish.
  defp check_slug_free(probe, live) do
    slug = Ash.Changeset.get_attribute(probe, :slug)
    locale = Ash.Changeset.get_attribute(probe, :locale)

    if (slug != live.slug or locale != live.locale) and is_binary(slug) and
         slug_taken?(probe.resource, live, slug, locale) do
      Ash.Changeset.add_error(probe, field: :slug, message: "has already been taken")
    else
      probe
    end
  end

  defp slug_taken?(resource, live, slug, locale) do
    query = Ash.Query.filter(resource, id != ^live.id and slug == ^slug and locale == ^locale)

    # A dynamic type's slugs are unique per type (the identity's third column).
    query =
      case Map.fetch(live, :type_definition_id) do
        {:ok, type_id} -> Ash.Query.filter(query, type_definition_id == ^type_id)
        :error -> query
      end

    # authorize?: false — an existence probe on the identity's own columns, the
    # same question the unique index answers for every caller regardless of
    # what they may read.
    Ash.exists?(query, authorize?: false, tenant: live.org_id)
  end

  # Every held attribute, not only the supplied ones: the probe's own changes
  # derive some from others (`DeriveSlug` fills a blanked slug, `DeriveAlias`
  # an alias pattern). An attribute the probe left alone reads back as the
  # view's value, i.e. whatever the copy already held.
  defp stage_attributes(held, resource, live, probe) do
    Enum.reduce(WorkingCopy.held_attributes(resource), held, fn name, acc ->
      key = to_string(name)
      value = WorkingCopy.dump(resource, name, Ash.Changeset.get_attribute(probe, name))

      if value == WorkingCopy.dump(resource, name, Map.get(live, name)),
        do: Map.delete(acc, key),
        else: Map.put(acc, key, value)
    end)
  end

  defp stage_relationships(held, resource, live, probe, params) do
    resource
    |> WorkingCopy.held_relationships()
    |> Enum.filter(fn {argument, _} -> supplied?(params, argument) end)
    |> Enum.reduce(held, fn {argument, relationship}, acc ->
      key = to_string(argument)
      live_ids = live_ids(live, relationship)
      base = WorkingCopy.held_ids(live, argument) || live_ids
      ids = resulting_ids(probe, argument, base)

      if MapSet.new(ids) == MapSet.new(live_ids),
        do: Map.delete(acc, key),
        else: Map.put(acc, key, ids)
    end)
  end

  defp supplied?(params, argument) do
    name = to_string(argument)
    Enum.any?([name, "add_" <> name, "remove_" <> name], &Map.has_key?(params, &1))
  end

  # The complete set wins when it was sent (`nil` there means "clear", as on
  # `:update`); otherwise the merge verbs apply to what the copy holds now.
  # `MergeArguments` on the probe has already refused a payload mixing both.
  defp resulting_ids(probe, argument, base) do
    case Ash.Changeset.fetch_argument(probe, argument) do
      {:ok, ids} ->
        ids |> List.wrap() |> normalize()

      :error ->
        name = to_string(argument)
        added = probe |> argument_ids(:"add_#{name}") |> normalize()
        removed = probe |> argument_ids(:"remove_#{name}") |> normalize() |> MapSet.new()

        (base ++ added) |> Enum.uniq() |> Enum.reject(&MapSet.member?(removed, &1))
    end
  end

  defp argument_ids(probe, argument) do
    case Ash.Changeset.fetch_argument(probe, argument) do
      {:ok, ids} -> List.wrap(ids)
      :error -> []
    end
  end

  defp normalize(ids), do: ids |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

  defp live_ids(live, relationship) do
    live
    # authorize?: false — ids only, of the record this write is already
    # authorized to change, and nothing read leaves the changeset (the same
    # argument `FoldWorkingCopy` makes for its row read).
    |> Ash.load!(relationship, authorize?: false, tenant: live.org_id, lazy?: false)
    |> Map.fetch!(relationship)
    |> Enum.map(&to_string(&1.id))
    |> Enum.sort()
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
