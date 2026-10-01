defmodule KilnCMS.CMS.WorkingCopy do
  @moduledoc """
  The working copy of a live document (docs/working-copy.md).

  A published record keeps two versions of its content: the one readers get —
  the columns every delivery read serves — and the one the editor is working
  on. The working copy lives on the same row: the title and body in
  `working_title` / `working_blocks`, every other held field in
  `working_fields`, all of it stamped by `working_copy_at`. Saving a published
  record never changes what the public sees; **Publish changes** (or a release,
  `KilnCMS.CMS.Releases`) promotes the whole copy at once (#1815).

  ## Which fields are held

  *Content* — what a reader sees on, or about, the entry — is held:

    * `title`, `blocks` (their own typed columns, so the block union's cast
      sanitizes the working body exactly as it does the live one);
    * `excerpt`, `seo_title`, `seo_description`, `seo_keywords`, `seo_image`,
      `canonical_url` — the listing and search-result text;
    * `custom_fields` — a dynamic type's whole schema lives here, so on those
      types this is most of the content;
    * `category_id`, `featured_image_id`, the tags and the curated related
      content — what the page shows next to the body;
    * `slug`, `path_alias` and `locale` — the address. A held rename leaves its
      301 (`Changes.RecordSlugRedirect`) when it is published, not when it is
      typed, so the old URL keeps working until the new one exists.

  *Operational* settings apply on Save, as they always have:

    * `audience` and the access passphrase — who may read the entry. A lock is
      a security decision; holding it back until someone also publishes text
      would leave the page open in the meantime (and in the other direction,
      it is the same switch a publish is). Applied at once, both ways.
    * `scheduled_at`, `unpublish_at`, `expiry_action`, `review_after_days` —
      workflow and lifecycle. They say *when* the live entry changes state,
      not what it says, and the schedulers read them off the row.
    * `type_definition_id` — which type an entry is; not content either.

  ## The lost-update guard

  An API `PATCH` or in-context editing still edits the live row. So that a
  later publish of the copy cannot silently overwrite such an edit, the copy
  records, per held key, a fingerprint of the live value it was based on
  (`working_base`), and `reconcile/1` sorts the keys at publish time into
  promote / keep live / conflict. `Changes.PromoteWorkingCopy` refuses an
  undecided conflict; `KilnCMS.CMS.Releases` blocks the item.

  ## The invariant

  The working columns are set only while the record is published.
  `:save_working_copy` refuses any other state at the row, `:publish_changes`
  and `:discard_changes` clear them, and the retiring transitions (`:unpublish`,
  `:archive` and their scheduled twins) fold the copy into the row before
  leaving `:published` — so a draft never carries a stale shadow of itself.

  A copy exists only while it runs ahead: `working_fields` holds just the
  fields that *differ* from the live row, and `working_copy_at` is stamped
  exactly while the title, the body or any held field differs.

  This module is the one place that reads the copy back: `view/1` is what the
  editor and the signed-in preview render, and `pending?/1` is what the
  "Live · draft" pill, the content list's *edited since publishing* marker and
  a release's readiness verdict all ask.
  """

  require Ash.Query

  @typedoc "Any content record — `KilnCMS.CMS.Page`, `Post`, `Entry` or a project type."
  @type content :: struct()

  # The held attributes beyond the title and body, in a stable order. Filtered
  # per resource by `held_attributes/1` (only some types have an excerpt).
  @held_attributes [
    :slug,
    :path_alias,
    :locale,
    :excerpt,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :canonical_url,
    :custom_fields,
    :category_id,
    :featured_image_id
  ]

  @doc """
  The attributes of `resource` a working copy holds, besides `title` and
  `blocks`. See "Which fields are held" in the moduledoc.
  """
  @spec held_attributes(module()) :: [atom()]
  def held_attributes(resource) do
    Enum.filter(@held_attributes, &Ash.Resource.Info.attribute(resource, &1))
  end

  @doc """
  The many-to-many relationships a working copy holds, as
  `{complete_set_argument, relationship}` — the tags and the curated related
  content. Read off the resource by the naming convention
  `KilnCMS.CMS.Content` declares them with (`tags` / `tag_ids`,
  `related_<type>s` / `related_<type>_ids`).
  """
  @spec held_relationships(module()) :: [{atom(), atom()}]
  def held_relationships(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :many_to_many and held_relationship?(&1.name)))
    |> Enum.map(&{argument_for(&1.name), &1.name})
  end

  defp held_relationship?(:tags), do: true
  defp held_relationship?(name), do: String.starts_with?(to_string(name), "related_")

  # `tags` → `tag_ids`, `related_pages` → `related_page_ids`. Existing atoms:
  # the arguments are declared by the same macro that declares the relationship.
  defp argument_for(name) do
    name
    |> to_string()
    |> String.replace_suffix("s", "")
    |> Kernel.<>("_ids")
    |> String.to_existing_atom()
  end

  @doc """
  The form params that belong to the working copy on `resource`: every held
  attribute, and each held relationship's complete-set argument with its
  `add_` / `remove_` merge verbs. `title` and `blocks` are not listed — they
  travel as `working_title` / `working_blocks`.
  """
  @spec held_param_keys(module()) :: [String.t()]
  def held_param_keys(resource) do
    attributes = Enum.map(held_attributes(resource), &to_string/1)

    relationships =
      Enum.flat_map(held_relationships(resource), fn {argument, _relationship} ->
        name = to_string(argument)
        [name, "add_" <> name, "remove_" <> name]
      end)

    attributes ++ relationships
  end

  @doc """
  Splits editor params into the held ones and the operational ones (see the
  moduledoc), dropping `title` and `blocks`, which are neither.
  """
  @spec split_params(module(), map()) :: {held :: map(), operational :: map()}
  def split_params(resource, params) do
    held_keys = held_param_keys(resource)

    params
    |> Map.drop(["title", "blocks"])
    |> Map.split(held_keys)
  end

  @doc """
  Whether `record` is live with edits that have not been published yet.

  `false` for anything not published, whatever the columns hold — see the
  invariant in the moduledoc.
  """
  @spec pending?(content() | nil) :: boolean()
  def pending?(%{state: :published, working_copy_at: %DateTime{}}), do: true
  def pending?(_record), do: false

  @doc """
  The record as the editor should see it: the working copy laid over the live
  row when one is pending, the row itself otherwise.

  Covers the title, the body and every held attribute. A loaded `belongs_to`
  whose key the copy changes is reset to `nil` rather than left naming the live
  record — `load_view/2` loads the held one instead. Everything that is not
  content — state, lock version, the operational settings — is the live row's,
  which is what the caller is about to save against.
  """
  @spec view(content()) :: content()
  def view(record) do
    if pending?(record) do
      record
      |> Map.merge(%{title: record.working_title, blocks: record.working_blocks || []})
      |> overlay_attributes()
    else
      record
    end
  end

  @doc """
  `view/1`, with the relationships `record` had loaded re-read for the working
  copy: a held category or featured image, the held tags and related content.
  `opts` are the read options (`actor:`/`tenant:` or `authorize?: false`) the
  caller loaded `record` with.
  """
  @spec load_view(content(), keyword()) :: content()
  def load_view(record, opts) do
    record |> with_held_relationships(opts) |> view() |> reload_belongs_to(record, opts)
  end

  @doc """
  The record with its loaded tags and related content replaced by the working
  copy's, when the copy holds them. The attributes stay the live row's: this is
  for a caller that keeps the row (the editor's `@record`, whose lock version
  and live values a save is judged against) but shows the copy's links.
  """
  @spec with_held_relationships(content(), keyword()) :: content()
  def with_held_relationships(record, opts) do
    if pending?(record) do
      record.__struct__
      |> held_relationships()
      |> Enum.reduce(record, &overlay_relationship(&2, &1, opts))
    else
      record
    end
  end

  defp overlay_relationship(record, {argument, relationship}, opts) do
    with ids when is_list(ids) <- held_ids(record, argument),
         loaded when is_list(loaded) <- Map.get(record, relationship) do
      Map.put(record, relationship, read_related(record.__struct__, relationship, ids, opts))
    else
      _not_held_or_not_loaded -> record
    end
  end

  # In the held order. A link whose target has gone since (or that this caller
  # may not read) is simply not shown; promotion would fail to relate it anyway.
  defp read_related(resource, relationship, ids, opts) do
    destination = Ash.Resource.Info.relationship(resource, relationship).destination

    records =
      destination
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(Keyword.take(opts, [:actor, :tenant, :authorize?]))
      |> Map.new(&{to_string(&1.id), &1})

    ids |> Enum.map(&Map.get(records, &1)) |> Enum.reject(&is_nil/1)
  end

  defp overlay_attributes(record) do
    resource = record.__struct__
    held = held_fields(record)

    Enum.reduce(held_attributes(resource), record, fn name, acc ->
      case Map.fetch(held, to_string(name)) do
        {:ok, stored} -> acc |> Map.put(name, cast(resource, name, stored)) |> drop_stale(name)
        :error -> acc
      end
    end)
  end

  # A loaded `belongs_to` over a key the copy moved would name the live record
  # beside the held id; nothing shown beats the wrong thing shown.
  defp drop_stale(record, attribute) do
    case belongs_to_over(record.__struct__, attribute) do
      nil -> record
      relationship -> drop_if_stale(record, relationship, Map.get(record, attribute))
    end
  end

  defp drop_if_stale(record, relationship, key) do
    case Map.get(record, relationship) do
      %{id: id} when id != key -> Map.put(record, relationship, nil)
      _matching_not_loaded_or_nil -> record
    end
  end

  defp reload_belongs_to(view, original, opts) do
    resource = view.__struct__

    names =
      for attribute <- held_attributes(resource),
          relationship = belongs_to_over(resource, attribute),
          relationship != nil,
          loaded?(original, relationship),
          Map.get(view, relationship) == nil and Map.get(view, attribute) != nil,
          do: relationship

    case names do
      [] -> view
      names -> Ash.load!(view, names, Keyword.take(opts, [:actor, :tenant, :authorize?]))
    end
  end

  defp loaded?(record, relationship) do
    case Map.get(record, relationship) do
      %Ash.NotLoaded{} -> false
      _loaded -> true
    end
  end

  defp belongs_to_over(resource, attribute) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find_value(fn
      %{type: :belongs_to, source_attribute: ^attribute, name: name} -> name
      _other -> nil
    end)
  end

  @doc """
  The text the working copy is measured against: the previous working copy when
  one is pending, else the published text. What "runs ahead" means, and what a
  field grant or block policy judges a working-copy write against.
  """
  @spec basis(content()) :: %{title: String.t() | nil, blocks: list()}
  def basis(record) do
    if pending?(record) do
      %{title: record.working_title, blocks: record.working_blocks || []}
    else
      %{title: record.title, blocks: record.blocks || []}
    end
  end

  @doc """
  The held fields stored on `record`, as stored: attribute names (strings) to
  JSON-native values, and each held relationship's argument name to a sorted
  list of id strings. Empty when nothing beyond the text is pending.
  """
  @spec held_fields(content()) :: map()
  def held_fields(%{working_fields: %{} = fields}), do: fields
  def held_fields(_record), do: %{}

  @doc """
  The ids the copy holds for one relationship argument (`:tag_ids`, …), or
  `nil` when it holds none and the live links stand.
  """
  @spec held_ids(content(), atom()) :: [String.t()] | nil
  def held_ids(record, argument) do
    case Map.fetch(held_fields(record), to_string(argument)) do
      {:ok, ids} when is_list(ids) -> ids
      _none -> nil
    end
  end

  @doc """
  The held attributes as values ready to write — `{name, value}` per stored
  key, cast back from storage — and the held relationship id sets.
  """
  @spec promotion(content(), [key()] | :all) :: %{
          attributes: [{atom(), term()}],
          relationships: [{atom(), [String.t()]}]
        }
  def promotion(record, keys \\ :all) do
    resource = record.__struct__
    held = record |> held_fields() |> only(keys)

    attributes =
      for name <- held_attributes(resource),
          {:ok, stored} <- [Map.fetch(held, to_string(name))],
          do: {name, cast(resource, name, stored)}

    relationships =
      for {argument, relationship} <- held_relationships(resource),
          {:ok, ids} <- [Map.fetch(held, to_string(argument))],
          is_list(ids),
          do: {relationship, ids}

    %{attributes: attributes, relationships: relationships}
  end

  defp only(held, :all), do: held
  defp only(held, keys), do: Map.take(held, keys)

  @doc """
  An attribute value as `working_fields` stores it: the attribute type's
  embedded (JSON-native) dump.
  """
  @spec dump(module(), atom(), term()) :: term()
  def dump(resource, name, value) do
    attribute = Ash.Resource.Info.attribute(resource, name)

    case Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints) do
      {:ok, dumped} -> dumped
      _error -> value
    end
  end

  @doc "A stored `working_fields` value cast back to the attribute's type."
  @spec cast(module(), atom(), term()) :: term()
  def cast(resource, name, stored) do
    attribute = Ash.Resource.Info.attribute(resource, name)

    case Ash.Type.cast_stored(attribute.type, stored, attribute.constraints) do
      {:ok, value} -> value
      _error -> stored
    end
  end

  # ── The lost-update guard ─────────────────────────────────────────────────

  @typedoc """
  A held key: `"title"`, `"blocks"`, a held attribute's name, or a held
  relationship's argument name (`"tag_ids"`, …).
  """
  @type key :: String.t()

  @typedoc """
  What publishing the copy does with each held key (`reconcile/1`):

    * `promote` — the copy's value goes live (the live value has not moved
      since the copy was based on it, or the key has no recorded base);
    * `keep_live` — the copy never changed it (a title carried along while
      only the body was edited), so whatever is live now stays;
    * `conflicts` — both moved: the live value changed after the draft was
      saved (an API `PATCH`, in-context editing) and the copy holds a
      different value. Never promoted without a decision.
  """
  @type reconciliation :: %{promote: [key()], keep_live: [key()], conflicts: [key()]}

  @doc """
  The fingerprint of a held key's value — what `working_base` records and
  `reconcile/1` compares. A SHA-256 over the value as the data layer stores
  it (block trees dumped, link ids sorted), with Erlang's deterministic term
  encoding: if that encoding ever changed across OTP releases the result is a
  reported conflict, never a silent overwrite.
  """
  @spec fingerprint(module(), key(), term()) :: String.t()
  def fingerprint(resource, key, value) do
    comparable =
      cond do
        key == "blocks" -> dump_blocks(resource, value)
        link_key?(resource, key) -> value |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort()
        attribute = attribute_named(resource, key) -> dump(resource, attribute, value)
        true -> value
      end

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(comparable, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The fingerprint of the live value of `key` on `record` — the row's own
  column, or for a held relationship the ids linked now.
  """
  @spec live_fingerprint(content(), key()) :: String.t()
  def live_fingerprint(record, key) do
    resource = record.__struct__
    fingerprint(resource, key, live_value(record, key))
  end

  @doc """
  Sorts a pending copy's held keys into what publishing it promotes, what it
  leaves live, and what conflicts — see `t:reconciliation/0`. Keys with no
  recorded base (a copy saved before 1.0 recorded them) promote, as they
  always did.
  """
  @spec reconcile(content()) :: reconciliation()
  def reconcile(record) do
    if pending?(record) do
      base = base_fingerprints(record)

      record
      |> held_keys()
      |> Enum.reduce(%{promote: [], keep_live: [], conflicts: []}, fn key, acc ->
        verdict = verdict(record, key, Map.get(base, key))
        Map.update!(acc, verdict, &(&1 ++ [key]))
      end)
    else
      %{promote: [], keep_live: [], conflicts: []}
    end
  end

  defp verdict(_record, _key, nil), do: :promote

  defp verdict(record, key, base) do
    cond do
      held_fingerprint(record, key) == base -> :keep_live
      live_fingerprint(record, key) == base -> :promote
      true -> :conflicts
    end
  end

  @doc "The recorded base fingerprints, by held key."
  @spec base_fingerprints(content()) :: %{key() => String.t()}
  def base_fingerprints(%{working_base: %{} = base}), do: base
  def base_fingerprints(_record), do: %{}

  defp held_keys(record) do
    ["title", "blocks"] ++ (record |> held_fields() |> Map.keys() |> Enum.sort())
  end

  defp held_fingerprint(record, "title"),
    do: fingerprint(record.__struct__, "title", record.working_title)

  defp held_fingerprint(record, "blocks"),
    do: fingerprint(record.__struct__, "blocks", record.working_blocks || [])

  defp held_fingerprint(record, key) do
    resource = record.__struct__
    stored = Map.get(held_fields(record), key)

    case attribute_named(resource, key) do
      nil -> fingerprint(resource, key, stored)
      name -> fingerprint(resource, key, cast(resource, name, stored))
    end
  end

  defp live_value(record, "blocks"), do: record.blocks || []

  defp live_value(record, key) do
    resource = record.__struct__

    case Enum.find(held_relationships(resource), fn {argument, _} ->
           to_string(argument) == key
         end) do
      {_argument, relationship} -> linked_ids(record, relationship)
      nil -> Map.get(record, attribute_named(resource, key) || :title)
    end
  end

  # Read fresh, never off a loaded list: the editor's `@record` carries the
  # COPY's links (`with_held_relationships/2`), not the live ones.
  defp linked_ids(record, relationship) do
    record
    # authorize?: false — link ids of a record the caller is already writing
    # or publishing; only a fingerprint of them leaves this function.
    |> Ash.load!(relationship, authorize?: false, tenant: record.org_id, lazy?: false)
    |> Map.fetch!(relationship)
    |> Enum.map(&to_string(&1.id))
  end

  defp link_key?(resource, key),
    do:
      Enum.any?(held_relationships(resource), fn {argument, _} -> to_string(argument) == key end)

  # The atom for a held attribute's name, from the fixed held list — never
  # built from the string.
  defp attribute_named(resource, key),
    do: Enum.find(held_attributes(resource) ++ [:title], &(to_string(&1) == key))

  @doc """
  The held relationship for a held key (`"tag_ids"` → `:tags`), or `nil`.
  """
  @spec relationship_for(module(), key()) :: atom() | nil
  def relationship_for(resource, key) do
    Enum.find_value(held_relationships(resource), fn {argument, relationship} ->
      if to_string(argument) == key, do: relationship
    end)
  end

  @doc """
  The held attribute for a held key (`"seo_title"` → `:seo_title`), or `nil`.
  """
  @spec attribute_for(module(), key()) :: atom() | nil
  def attribute_for(resource, key),
    do: Enum.find(held_attributes(resource), &(to_string(&1) == key))

  @doc """
  Whether two block trees carry the same content.

  Compared as the data layer would store them (`Ash.Type.dump_to_native/3`),
  not as structs: a tree loaded from the row and one cast from the editor's
  params differ in Ecto metadata (`:loaded` against `:built`) and nothing else,
  and the whole point of asking is to ignore exactly that.
  """
  @spec same_blocks?(module(), list() | nil, list() | nil) :: boolean()
  def same_blocks?(resource, left, right) do
    dump_blocks(resource, left) == dump_blocks(resource, right)
  end

  defp dump_blocks(resource, blocks) do
    attribute = Ash.Resource.Info.attribute(resource, :blocks)

    case Ash.Type.dump_to_native(attribute.type, List.wrap(blocks), attribute.constraints) do
      {:ok, dumped} -> dumped
      _error -> List.wrap(blocks)
    end
  end
end
