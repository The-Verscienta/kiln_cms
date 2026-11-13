defmodule KilnCMS.CMS.FieldDefinition do
  @moduledoc """
  A **runtime-defined custom field** on a content type — the admin-UI-first
  half of the schema (the Directus "add a field in the UI" workflow), within the
  constraints of decision D4.

  D4 keeps content *types* as compile-time Ash resources; this makes their
  *fields* data-driven. An admin defines typed fields per content type here
  (name, type, whether required, select options, …); the values live in the
  `custom_fields` map on each content record and are coerced + validated against
  these definitions on write (see `KilnCMS.CMS.Changes.ApplyCustomFields`). The
  content editor renders an input per definition, so editors add structured
  fields without a code change or migration.

  A definition is scoped to **exactly one** of four owners (D17, R3):

    * `content_type` — a compiled content type's atom (`:page`), the original
      D4 scope;
    * `type_definition_id` — an admin-defined dynamic type
      (`KilnCMS.CMS.TypeDefinition`), whose entire schema is these rows; or
    * `link_of_id` — a `:reference` definition, which makes the row a **link
      field**: data about each connection the reference makes ("Quantity" on
      the link from a recipe to an ingredient), stored in the snapshot's
      `"link"` map and on the edge's `metadata` (R3 in
      `docs/relationships-plan.md`). A link field is coerced by the same
      `ApplyCustomFields` rules as any other field, but only the plain types
      in `link_field_types/0`, and it cannot own link fields itself — nesting
      stops at one level. It is never a field of a content type: `for_type`
      and `for_definition` do not list it, they load it into its parent's
      `link_fields`;
    * `group_of_id` — a `:group` definition, which makes the row a **sub-field**
      of that group: one key of the object (or of each object in the list, when
      the group is `multiple`) the group's value holds — "Unit" on each row of
      a `dosages` group. Values live inside the group's own value, not in a
      snapshot's `"link"` map, which is why this is a column of its own rather
      than a second meaning of `link_of_id`. The same rules otherwise: only
      `link_field_types/0`, no nesting, never listed by `for_type` or
      `for_definition` — they load it into the group's `group_fields`.

  This deliberately does *not* replace hand-declared attributes: core, queryable,
  or strongly-typed fields still belong in the resource. It covers the long tail
  of editor-owned fields that would otherwise mean a migration per field.

  Not every field is editor-filled: a `:computed` definition carries a
  `compute` formula (`KilnCMS.CMS.Computed`) and derives its value from the
  rest of the document instead (#429).

  How a field is edited can be chosen per field too (#2284): `widget` picks
  the editor input — a select's radio buttons, plain text on one line, a
  plugin type's own — from what `KilnCMS.CMS.FieldWidgets` offers for the
  field's settings. It never changes what is stored or delivered.

  ## A field type this release does not know

  A row can hold a `field_type` this release does not register (#2605): one a
  newer release added, read after a rollback, or a type whose plugin was
  removed. Every read leaves such a row out
  (`KilnCMS.CMS.Preparations.RegisteredFieldTypes`), so the editor, coercion,
  filters, the schema export and freshly computed delivery skip the field as
  if it were not defined. Its stored values are kept, not erased, by every
  write (`KilnCMS.CMS.Changes.ApplyCustomFields`), and they are still what a
  record holds: the content API's raw `custom_fields` and an as-stored replay
  (a point-in-time read) return them, unless the field is private, which
  stays masked. Deleting the field is what withdraws them; the Fields screen
  lists such rows apart with a delete. See `unknown_type?/1` and
  `all_types_context/0`.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource, AshJsonApi.Resource, AshOban]

  # A JSON:API type only — no routes. It exists so
  # `/api/json/type-definitions?include=field_definitions` can serialize a
  # dynamic type's field schema; the fields are read through the type, under
  # this resource's own read policy (editor-or-above).
  json_api do
    type "field_definition"
    includes [:group_fields]
  end

  @doc """
  What an editor reads for `value` of a `:select` field: its label in
  `option_labels`, or the value itself.
  """
  @spec option_label(map(), String.t()) :: String.t()
  def option_label(definition, value) do
    case Map.get(definition, :option_labels) do
      %{} = labels -> Map.get(labels, value) || value
      _none -> value
    end
  end

  @doc """
  The stored value an editor's `text` names on a `:select` field: an option
  itself, else the option whose label it is (ignoring case and surrounding
  space), else `text` unchanged — a new term on an open vocabulary, or a
  stray the field's validation will name.
  """
  @spec option_value(map(), String.t()) :: String.t()
  def option_value(definition, text) do
    options = Map.get(definition, :options) || []
    labels = Map.get(definition, :option_labels) || %{}
    wanted = text |> String.trim() |> String.downcase()

    cond do
      text in options ->
        text

      found = Enum.find(options, &(labels |> Map.get(&1, "") |> String.downcase() == wanted)) ->
        found

      true ->
        text
    end
  end

  @doc """
  The value types a custom field may declare: the built-ins plus every
  plugin-contributed `Kiln.FieldType` (see `KilnCMS.CMS.FieldTypes`).
  """
  @spec field_types() :: [atom()]
  def field_types, do: KilnCMS.CMS.FieldTypes.names()

  @link_field_types [:string, :text, :integer, :float, :boolean, :date, :datetime, :url, :select]

  @doc """
  The field types a link field (`link_of_id`, R3) may have: the plain, scalar
  ones. They render as one input on a connection's row in the editor and
  filter as one jsonb value on the edge (`custom_filter[field.link.name]`).
  A media snapshot, a reference (which would nest link data in link data), a
  formula over the document or a composite plugin type has neither.
  """
  @spec link_field_types() :: [atom()]
  def link_field_types, do: @link_field_types

  @doc """
  The link fields a definition declares (R3): its loaded `link_fields`, or
  `[]` for a definition that is not a `:reference`. `for_type` and
  `for_definition` load them; reading them off a definition that was read
  another way raises rather than answering "none", because "none" would
  silently drop every link value a write carries.
  """
  @spec link_fields(t() | map()) :: [t()]
  def link_fields(%{field_type: :reference, link_fields: %Ash.NotLoaded{}} = definition),
    do: raise(ArgumentError, "link_fields not loaded on field #{inspect(definition.name)}")

  def link_fields(%{field_type: :reference, link_fields: fields}) when is_list(fields), do: fields
  def link_fields(_definition), do: []

  @doc """
  The sub-fields a `:group` definition declares: its loaded `group_fields`, or
  `[]` for any other type. Raises when they were not loaded, for the reason
  `link_fields/1` does — "no sub-fields" would refuse every key a write sends.
  """
  @spec group_fields(t() | map()) :: [t()]
  def group_fields(%{field_type: :group, group_fields: %Ash.NotLoaded{}} = definition),
    do: raise(ArgumentError, "group_fields not loaded on field #{inspect(definition.name)}")

  def group_fields(%{field_type: :group, group_fields: fields}) when is_list(fields), do: fields
  def group_fields(_definition), do: []

  @doc """
  The definition a sub-field hangs off, if any: its reference (a link field)
  or its group (a group sub-field).
  """
  @spec parent_id(t() | map()) :: Ash.UUID.t() | nil
  def parent_id(definition),
    do: Map.get(definition, :link_of_id) || Map.get(definition, :group_of_id)

  @doc """
  The machine name a field's label suggests: lowercase ASCII letters, digits
  and underscores, starting with a letter — the shape the `name` validation
  below accepts.

  Accents fold to their base letter and any other run of characters becomes a
  single underscore. A label that starts with a digit gets a `field_` prefix
  rather than losing the digit, and a label with nothing usable in it suggests
  `""`, which the validation then refuses on its own terms.

      iex> KilnCMS.CMS.FieldDefinition.name_from_label("Shoe size (EU)")
      "shoe_size_eu"

      iex> KilnCMS.CMS.FieldDefinition.name_from_label("Crème brûlée")
      "creme_brulee"

      iex> KilnCMS.CMS.FieldDefinition.name_from_label("3D model")
      "field_3d_model"
  """
  @spec name_from_label(String.t() | nil) :: String.t()
  def name_from_label(label) when is_binary(label) do
    name =
      label
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    name = if name =~ ~r/\A[0-9]/, do: "field_" <> name, else: name

    name |> String.slice(0, KilnCMS.Limits.line()) |> String.trim_trailing("_")
  end

  def name_from_label(_label), do: ""

  @doc """
  Whether a definition is **orphaned**: scoped to a compiled content type that
  no longer exists (#1770).

  A write cannot produce one — `Validations.KnownContentType` refuses an
  unregistered type — but an upgraded site can hold one: a plugin removed, a
  compiled type renamed or deleted. The stored name either has no atom at all
  (it loads as a `KilnCMS.CMS.OrphanedContentType`) or is an atom the registry
  no longer lists. Either way nothing renders, validates or delivers the field;
  the Fields screen lists it apart so an admin can delete it.

  A dynamic-scoped definition is never orphaned by this test: its
  `type_definition_id` is a foreign key to a row that still exists.
  """
  @spec orphaned?(t() | map()) :: boolean()
  def orphaned?(%{type_definition_id: nil, content_type: %KilnCMS.CMS.OrphanedContentType{}}),
    do: true

  def orphaned?(%{type_definition_id: nil, content_type: type})
      when is_atom(type) and not is_nil(type),
      do: not KilnCMS.CMS.ContentTypes.type?(type)

  def orphaned?(_definition), do: false

  @doc """
  Whether `definition`'s `field_type` is one this release does not register
  (#2605): stored text with no atom (it loads as a `KilnCMS.Types.UnknownAtom`),
  or an atom `KilnCMS.CMS.FieldTypes.names/0` no longer lists.

  A newer release's type read after a rollback, or a type whose plugin was
  removed. Such a row is left out of every ordinary read
  (`Preparations.RegisteredFieldTypes`); a read that passes
  `all_types_context/0` sees it, and must handle it.

      iex> KilnCMS.CMS.FieldDefinition.unknown_type?(%{field_type: :string})
      false

      iex> KilnCMS.CMS.FieldDefinition.unknown_type?(%{field_type: %KilnCMS.Types.UnknownAtom{value: "x"}})
      true
  """
  @spec unknown_type?(t() | map()) :: boolean()
  def unknown_type?(%{field_type: %KilnCMS.Types.UnknownAtom{}}), do: true

  def unknown_type?(%{field_type: type}) when is_atom(type) and not is_nil(type),
    do: type not in KilnCMS.CMS.FieldTypes.names()

  def unknown_type?(_definition), do: false

  @doc """
  The read `context` that includes rows of an unknown field type
  (`unknown_type?/1`), which every read leaves out otherwise
  (`Preparations.RegisteredFieldTypes`). Top-level only: a relationship the
  read loads (`link_fields`, `group_fields`) stays filtered.

      CMS.list_field_definitions!(actor: actor, context: FieldDefinition.all_types_context())
  """
  @spec all_types_context() :: map()
  def all_types_context, do: %{field_types: :all}

  @doc """
  The content type names a `:reference` definition may point at: its
  `target_types` when it lists any (a polymorphic field, R2), else its single
  `target_type`, else none. Every reader of "which types does this field
  allow" goes through here, so the two options can't be read differently.

      iex> KilnCMS.CMS.FieldDefinition.reference_targets(%{target_type: "page", target_types: []})
      ["page"]

      iex> KilnCMS.CMS.FieldDefinition.reference_targets(%{target_type: nil, target_types: ["page", "post"]})
      ["page", "post"]
  """
  @spec reference_targets(t() | map()) :: [String.t()]
  def reference_targets(definition) do
    case Map.get(definition, :target_types) do
      [_ | _] = types ->
        types

      _none ->
        case Map.get(definition, :target_type) do
          type when is_binary(type) and type != "" -> [type]
          _none -> []
        end
    end
  end

  admin do
    resource_group :content
    table_columns [:content_type, :name, :label, :field_type, :required, :position]
    relationship_display_fields [:label]
    label_field :label
  end

  postgres do
    table "field_definitions"
    repo KilnCMS.Repo

    references do
      # Deleting a reference field deletes its link fields; their values went
      # with the parent's key (`Changes.SyncFieldValues`).
      # No index of its own: `unique_link_field` leads with (org_id, link_of_id).
      reference :link_of, on_delete: :delete

      # Deleting a group deletes its sub-fields; their values went with the
      # group's key. Indexed by `unique_group_field`, as above.
      reference :group_of, on_delete: :delete
    end
  end

  oban do
    scheduled_actions do
      # Hourly, but it does the work once a day: on the first tick after the
      # SITE's midnight (`Computed.DailyRefresh.due?/1`). A daily cron would be
      # a UTC midnight, a day late for half the world's mornings.
      schedule :refresh_time_dependent, "7 * * * *" do
        action :refresh_time_dependent
        queue :default
        worker_module_name KilnCMS.CMS.FieldDefinition.Workers.RefreshTimeDependent
      end
    end
  end

  actions do
    defaults [:read]

    # `require_atomic? false` because `BustTypeRegistry` runs `after_action`, and
    # an atomic destroy has no record to hand it. A field-definition destroy is
    # a rare admin action, so losing the atomic path costs nothing.
    destroy :destroy do
      primary? true
      require_atomic? false
    end

    default_accept [
      :content_type,
      :type_definition_id,
      :link_of_id,
      :group_of_id,
      :name,
      :label,
      :field_type,
      :required,
      :options,
      :option_labels,
      :allow_custom,
      :format,
      :widget,
      :target_type,
      :target_types,
      :multiple,
      :min_items,
      :max_items,
      :max_sources,
      :on_target_delete,
      :help_text,
      :position,
      :section,
      :width,
      :default,
      :default_source,
      :default_field,
      :compute,
      :names_record,
      :searchable,
      :deliver_plain,
      :plain_breaks,
      :deliver_portable,
      :localization,
      :inverse_label,
      :inverse_name,
      :private,
      :schema_org_property,
      :validation,
      :visible_when,
      :required_when,
      :selection
    ]

    create :create, primary?: true

    # Non-atomic: the KnownContentType validation runs in Elixir.
    update :update do
      primary? true
      require_atomic? false
    end

    # Moves computed fields whose formula calls `today()` to the site's new
    # day: re-derives and re-fires the published records of every type with
    # one (`KilnCMS.CMS.Computed.DailyRefresh`). Run by the scheduled action
    # above; `today` forces a refresh against that date instead of waiting for
    # the day to change. Returns how many records were written.
    action :refresh_time_dependent, :integer do
      argument :today, :date, allow_nil?: true

      run fn input, _context ->
        {:ok, KilnCMS.CMS.Computed.DailyRefresh.tick(today: input.arguments[:today])}
      end
    end

    # All custom-field definitions for one content type, in editor display order.
    # Used by the editor (to render inputs) and the content write change (to
    # coerce/validate values) — both call it with `authorize?: false`.
    #
    # Each `:reference` definition comes with its link fields (R3) loaded, and
    # each `:group` with its sub-fields, so every reader of a type's schema —
    # coercion, edges, filters, the editor, the schema export — sees the
    # connection data and the row shape it declares.
    read :for_type do
      argument :content_type, :atom, allow_nil?: false
      filter expr(content_type == ^arg(:content_type))
      prepare build(sort: [position: :asc, name: :asc], load: [:link_fields, :group_fields])
    end

    # The dynamic-type equivalent of `for_type`: all field definitions owned by
    # one `TypeDefinition`, in editor display order.
    read :for_definition do
      argument :type_definition_id, :uuid, allow_nil?: false
      filter expr(type_definition_id == ^arg(:type_definition_id))
      prepare build(sort: [position: :asc, name: :asc], load: [:link_fields, :group_fields])
    end

    # The reverse fields a content type shows (R4): every top-level
    # `:reference` definition that may point at `target_type` (as its one
    # `target_type` or among its `target_types`) and names its other side
    # (`inverse_name`). Read by `KilnCMS.CMS.ReverseFields`.
    read :inverse_of do
      argument :target_type, :string, allow_nil?: false

      filter expr(
               field_type == :reference and is_nil(link_of_id) and not is_nil(inverse_name) and
                 (target_type == ^arg(:target_type) or
                    fragment("? = ANY(?)", ^arg(:target_type), target_types))
             )

      prepare build(sort: [position: :asc, name: :asc], load: [:link_fields])
    end
  end

  policies do
    # The daily computed-field refresh walks EVERY org, so it is not an admin
    # verb: first, so the admin bypass below can't admit one. The scheduler
    # runs it; so may the `:computed_fields` system actor (an operator's rpc).
    policy action(:refresh_time_dependent) do
      authorize_if AshOban.Checks.AshObanInteraction
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :computed_fields}
    end

    # Admins own the schema (defining/removing fields is an admin concern).
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Editors may read definitions so the content editor can render the fields.
    #
    # The system actor reads them too (#1402): firing a document needs the field
    # schema to turn `custom_fields` values into JSON-LD
    # (`KilnCMS.Firing.CustomFields`). Read-only — defining a field stays admin,
    # through the policy below and the bypass above.
    policy action_type(:read) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: [
                      :cms_bookkeeping,
                      :cms_registry,
                      :computed_fields,
                      :events,
                      :firing,
                      :localization,
                      :schema_export
                    ]}

      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Only admins define, change or remove fields.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  preparations do
    # A row whose `field_type` this release does not register (#2605) — a
    # newer release's type after a rollback, a removed plugin's — is left out
    # of every read, in SQL, unless the read passes `all_types_context/0`.
    # Nothing downstream has a clause for such a type.
    prepare KilnCMS.CMS.Preparations.RegisteredFieldTypes
  end

  changes do
    # A formula belongs to a `:computed` field only — drop it on any other type
    # so switching an existing computed field away isn't a dead end (#429).
    change KilnCMS.CMS.Changes.ClearCompute

    # A dynamic default (#2286) must fit the field's type, replaces the static
    # `default`, and names a sibling only for `:copy_of`.
    change KilnCMS.CMS.Changes.ClearDefaultSource

    # Same for `multiple`: only a `:media` field (a gallery), a `:reference`
    # field (a list of references), a `:group` (repeating rows) or a
    # top-level scalar list type (`ScalarLists.types/0`: terms, phrases,
    # numbers, dates, links, …) can hold a list, so the flag — and
    # `allow_custom` with it — and the
    # `min_items`/`max_items` bounds that go with it — drop on any other type
    # rather than lingering on a field they mean nothing to.
    change KilnCMS.CMS.Changes.ClearMultiple

    # Option labels name options: none outlives its option, and a field that
    # is no longer a select keeps none.
    change KilnCMS.CMS.Changes.PruneOptionLabels

    # A link field (R3) lives inside its connection's value, and a group
    # sub-field inside its group's, so the options
    # that act on a record-level field — search indexing, naming the record,
    # per-locale behaviour — drop rather than claim something nothing honours.
    change KilnCMS.CMS.Changes.ClearLinkFieldOptions

    # `max_sources`, `on_target_delete` and `selection` speak about a
    # reference's targets, so they drop on any other type — a link field
    # included.
    change KilnCMS.CMS.Changes.ClearReferenceOptions

    # `deliver_plain` speaks about a `:text` field's HTML, so it drops on any
    # other type — and on a link field, whose value delivery never projects.
    # `plain_breaks` shapes that rendition, so it drops with it.
    change KilnCMS.CMS.Changes.ClearDeliverPlain

    # `deliver_portable` converts a rich `:text` field's HTML, so it drops on
    # any other type, on a `:plain` one, and on a link or group sub-field.
    change KilnCMS.CMS.Changes.ClearDeliverPortable

    # The editor input (#2284) is picked from what the field's settings offer
    # (`KilnCMS.CMS.FieldWidgets`), so one those settings no longer offer —
    # after a type change, a `multiple` flip, rich text — drops, unless this
    # write names the widget itself (then `Validations.FieldWidget` refuses).
    # After `ClearMultiple`, which settles `multiple` and `allow_custom`.
    change KilnCMS.CMS.Changes.ClearWidget

    # The other side's name (R4) belongs to a top-level `:reference` field,
    # and a label alone suggests its machine name, as a field's label does.
    change KilnCMS.CMS.Changes.ClearInverse

    # A `:user` field names a console account, which Kiln never delivers
    # (#2044): it is private whatever was submitted.
    change KilnCMS.CMS.Changes.PrivateUserField

    # Whether a type is event-shaped (#480) is decided by whether it carries a
    # `datetime_range` field, so the cached answer has to drop on a field write,
    # not only on a type write.
    change KilnCMS.CMS.Changes.BustTypeRegistry, on: [:create, :update, :destroy]

    # Stored `custom_fields` keys follow their definition: a destroy purges the
    # key, a rename moves the values to the new one. Left alone, both strand a
    # key no definition declares, and `ApplyCustomFields` folds those out of
    # whatever write touches each record next — which is how an unrelated title
    # edit came to destroy three paragraphs of prose. A rename never asked for
    # that at all; a destroy did, but here, not months later.
    change KilnCMS.CMS.Changes.SyncFieldValues, on: [:update, :destroy]
  end

  validations do
    # A field belongs to exactly one owner: a compiled type, a dynamic one, a
    # reference field (a link field, R3) or a group (a sub-field).
    validate KilnCMS.CMS.Validations.OneFieldScope

    # A link field's parent is a top-level `:reference` field of the same
    # site, and the link field is one of the plain types.
    validate KilnCMS.CMS.Validations.LinkField

    # A sub-field's parent is a top-level `:group` field of the same site, and
    # the sub-field is one of the plain types.
    validate KilnCMS.CMS.Validations.GroupField

    # When compiled-scoped, the content type must be a real, registered
    # KilnCMS content type (no-op when `content_type` is nil).
    validate KilnCMS.CMS.Validations.KnownContentType

    # `field_type` must be registered: a built-in or a plugin `Kiln.FieldType`.
    validate KilnCMS.CMS.Validations.KnownFieldType

    # `name` is the key inside the `custom_fields` map and is surfaced in the
    # delivery API, so keep it a safe machine identifier.
    validate match(:name, ~r/\A[a-z][a-z0-9_]*\z/) do
      message "must be lowercase letters, digits and underscores, starting with a letter"
    end

    # A :select field is meaningless without choices.
    validate KilnCMS.CMS.Validations.SelectOptions

    # A widget the write names must be one the field offers (#2284).
    validate KilnCMS.CMS.Validations.FieldWidget

    # A :reference field must target known content types (compiled or
    # dynamic): one through `target_type`, or several through `target_types`.
    validate KilnCMS.CMS.Validations.ReferenceTarget

    # A reverse field's machine name is a safe identifier, unique among the
    # reverse fields of every type the reference may point at (R4).
    validate KilnCMS.CMS.Validations.InverseName

    # `min_items` may not exceed `max_items` on a list field.
    validate KilnCMS.CMS.Validations.ItemBounds

    # A :computed field must carry a `compute` formula that parses — and no
    # other type may carry one.
    validate KilnCMS.CMS.Validations.ComputeExpression

    # `copy_of` names a sibling of the same type (#2286).
    validate KilnCMS.CMS.Validations.DefaultSource

    # A private field (#2044) is a plain top-level type, and nothing copies
    # its value somewhere public.
    validate KilnCMS.CMS.Validations.PrivateField
    validate KilnCMS.CMS.Validations.ReadGrantedStaysPrivate, on: :update

    # Value constraints (#2276) are well-formed, fit the field's type, and
    # its default satisfies them.
    validate KilnCMS.CMS.Validations.FieldConstraints

    # Switching `unique` on over values that already repeat is refused (#2276).
    validate KilnCMS.CMS.Validations.UniqueFieldClean
    # `visible_when` / `required_when` are well-formed rules over this
    # field's siblings, with no cycle (#2277). On destroy it refuses to
    # remove a field other rules read.
    validate KilnCMS.CMS.Validations.FieldCondition, on: [:create, :update, :destroy]

    # `selection` (#2285) is a well-formed filter over the targets' own
    # shape, and a field it names cannot turn private or lose its equality.
    validate KilnCMS.CMS.Validations.ReferenceSelection, on: [:create, :update]
  end

  # Multi-tenancy (epic #336): a field belongs to the same site as the content
  # type (compiled type-name or dynamic `TypeDefinition`) it customizes.
  # `global?: true` keeps the tenant optional; tenant-less reads/writes land in
  # the default org via the `org_id` default.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create,
    # else the default org; never accepted from input (`writable?: false`, absent
    # from `default_accept`) — the cross-site boundary.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Which compiled content type this field is attached to (atom, e.g.
    # `:page`) — nil for a field owned by a dynamic type (see the
    # `type_definition` relationship and `Validations.OneFieldScope`).
    #
    # Stored as text like `:atom`, but a stored name with no existing atom
    # loads as a `KilnCMS.CMS.OrphanedContentType` rather than failing the
    # read (#1770) — see `orphaned?/1`.
    attribute :content_type, KilnCMS.CMS.Types.StoredContentType, public?: true

    # Machine key inside the `custom_fields` map.
    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Human label shown in the editor and (optionally) on delivery.
    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # The value type: a built-in or a plugin `Kiln.FieldType`
    # (`KilnCMS.CMS.FieldTypes.names/0`), checked on write by
    # `Validations.KnownFieldType`.
    #
    # `KnownAtom`, so a row whose type this release does not know (written by
    # a newer release before a rollback, or by a plugin since removed) loads
    # as a `KilnCMS.Types.UnknownAtom` instead of failing every read that
    # meets it (#2605). Ordinary reads never see such a row:
    # `Preparations.RegisteredFieldTypes` leaves it out. See
    # `unknown_type?/1`.
    #
    # No `one_of`: the registry is compile-time too, but as a constraint it
    # would put the installed plugin set into the JSON:API schema's enum (a
    # spec diff per plugin), and make this resource compile through
    # `FieldTypes` into every plugin module (a compile-cycle risk).
    attribute :field_type, KilnCMS.Types.KnownAtom do
      default :string
      allow_nil? false
      public? true
    end

    # Whether the editor must supply a value.
    attribute :required, :boolean, allow_nil?: false, default: false, public?: true

    # Choices for a `:select` field (ignored otherwise).
    attribute :options, {:array, :string}, allow_nil?: false, default: [], public?: true

    # What an editor reads for each option: `%{"transforming_phlegm" =>
    # "Transforming phlegm"}`, keyed by the stored value. The value stays what
    # is stored, filtered on and delivered — a label is the editor's view of
    # it, and a write naming the label stores the value
    # (`Changes.ApplyCustomFields`). An option with no label is its own label.
    # Pruned to the current options, and emptied on every other type
    # (`Changes.PruneOptionLabels`).
    attribute :option_labels, :map, allow_nil?: false, default: %{}, public?: true

    # Whether a `multiple` `:select` field takes terms beyond its `options` —
    # an **open vocabulary** ("Western Properties" grows with every herb).
    # `options` then seeds the picker's suggestions rather than bounding the
    # value, and may be empty. A term an editor adds does not join `options`:
    # the list stays admin-authored, and the picker suggests terms already in
    # use on the type besides (`KilnCMS.CMS.SelectTerms`). Cleared on every
    # field that is not a top-level multiple select (`Changes.ClearMultiple`).
    attribute :allow_custom, :boolean, allow_nil?: false, default: false, public?: true

    # How a `:text` field is edited: `:rich` (the default) puts the TipTap
    # editor on it — paragraphs, bold, italic, links, lists — and sanitizes
    # the stored HTML on write to the rich-text block's allow-list; `:plain`
    # keeps the bare textarea and stores the text as typed, for a field that
    # must stay plain (a short note, a code). Either way the value is a
    # string, so delivery is unchanged. Ignored on every other type.
    attribute :format, :atom do
      allow_nil? false
      default :rich
      constraints one_of: [:rich, :plain]
      public? true
    end

    # Which editor input the field uses (#2284): `"radios"` for a select,
    # `"single_line"` for plain text, a plugin type's own (`"stars"`). `nil`
    # is the type's default, today's input. Editor-only — storage, coercion
    # and delivery never read it. Chosen from `KilnCMS.CMS.FieldWidgets.allowed/1`
    # (`Validations.FieldWidget`), cleared when the field's settings stop
    # offering it (`Changes.ClearWidget`); read it through
    # `FieldWidgets.resolve/1`, never directly. A string, not an atom: a
    # plugin's widget names are the registry's today, and a name a plugin
    # later drops must not fail every read of the definitions that stored it.
    attribute :widget, :string, public?: true, constraints: [max_length: 64]

    # The content type a `:reference` field points at — a type name string
    # ("page", "recipe", …), compiled or dynamic (ignored otherwise).
    attribute :target_type, :string, public?: true

    # The content types a **polymorphic** `:reference` field may point at
    # (R2) — several type names, set *instead of* `target_type` (exactly one
    # of the two is set, `Validations.ReferenceTarget`). Each stored snapshot
    # names its own `"type"`, so a value is self-describing; a write must name
    # the type of every item when more than one is allowed. Empty for a
    # single-type field, which keeps the documented `target_type`.
    attribute :target_types, {:array, :string}, allow_nil?: false, default: [], public?: true

    # Whether a `:media` field holds a **gallery** — an ordered list of media
    # snapshots — or a `:reference` field a **list of references** (ordered
    # `{id, type, slug, title}` snapshots), or a `:group` **repeating rows**
    # (a list of objects), or a `:select` **several terms** (a list of
    # strings), or a top-level scalar field a **list of its values** (phrases,
    # numbers, dates, links…, `KilnCMS.CMS.ScalarLists`), rather than a
    # single one. Off by default, so every
    # existing field keeps its single-value shape. Ignored
    # (and cleared, see `Changes.ClearMultiple`) on every other type. Flipping
    # it on an existing field reshapes the stored values
    # (`Changes.SyncFieldValues`): a single becomes a one-item list, and a list
    # keeps only its first item.
    attribute :multiple, :boolean, allow_nil?: false, default: false, public?: true

    # Bounds on how many items a `multiple` field holds once it holds any (an
    # empty optional field is still allowed — `required` asks for at least
    # one). `nil` means unbounded. Cleared with `multiple` (`ClearMultiple`).
    # Enforced on write by `Changes.ApplyCustomFields`; tightening one leaves
    # stored values alone until that record's field is next written.
    attribute :min_items, :integer, public?: true, constraints: [min: 0]
    attribute :max_items, :integer, public?: true, constraints: [min: 1]

    # The other end's bound (R1b): how many source records may connect to any
    # one target through this `:reference` field ("each Author is on at most 3
    # Books"). `nil` means no limit. Single and `multiple` fields alike. It is
    # checked where the edge is written — inside the source's own write, under
    # a per-target advisory lock (`KilnCMS.CMS.ContentLinks`) — and only for a
    # target the write adds: removing or reordering is never refused, and
    # tightening it leaves existing connections alone. Cleared on every other
    # type (`Changes.ClearReferenceOptions`).
    attribute :max_sources, :integer, public?: true, constraints: [min: 1]

    # What purging a target does to this field's connections to it (R5):
    # `:keep` (the default, and what every field did before) leaves them as
    # broken references; `:clear` removes the target from every referrer's
    # value, as one system write per referrer; `:restrict` refuses the purge
    # while any connection through this field points at it. Purge only —
    # trash keeps edges, so a restore needs nothing
    # (`Changes.ApplyTargetDeleteRules`). Always `:keep` on any type but
    # `:reference`.
    attribute :on_target_delete, :atom do
      allow_nil? false
      default :keep
      constraints one_of: [:keep, :clear, :restrict]
      public? true
    end

    # What the **other side** calls this relationship (R4): the reverse field
    # every target record shows in its editor, listing the records that
    # connect to it through this field — "Recipes using this ingredient" on an
    # Ingredient, for a Recipe's `ingredients`. `inverse_label` is what an
    # editor reads; `inverse_name` the machine name GraphQL's
    # `referencedBy(inverse:)` and `KilnCMS.SchemaExport` use, suggested from
    # the label when left blank (`Changes.ClearInverse`). Both nil — no reverse
    # field — by default, and on anything but a top-level `:reference`.
    attribute :inverse_label, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :inverse_name, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Whether the value is for the site's editors and admins only (#2044):
    # kept out of every fired artifact and every read below editor
    # (`KilnCMS.CMS.PrivateFields`). Plain top-level types only, and never
    # with `searchable`, `names_record`, `deliver_plain`, `deliver_portable`
    # or a `:fallback` localization (`Validations.PrivateField`). Always on for a `:user`
    # field (`Changes.PrivateUserField`). Flipping it re-fires the type's
    # published documents (`Changes.BustTypeRegistry`).
    attribute :private, :boolean, allow_nil?: false, default: false, public?: true

    # What a `:reference` field's targets are to the document in schema.org
    # terms (#2044): `:author` or `:contributor`. The fired `:json_ld` main
    # node, and the JSON-LD inlined in Kiln's own pages, then carry one
    # `Person` per readable target, in the field's order
    # (`KilnCMS.Firing.Bylines`). Nil — no structured-data meaning — by
    # default, and cleared on anything but a top-level `:reference`
    # (`Changes.ClearReferenceOptions`). Setting or clearing it re-fires the
    # type's published documents (`Changes.BustTypeRegistry`).
    attribute :schema_org_property, :atom do
      constraints one_of: [:author, :contributor]
      public? true
    end

    # Value constraints an editor's input must satisfy (#2276), as string keys:
    # `min`/`max` (numbers), `min_length`/`max_length`/`pattern`/
    # `pattern_message` (text) and `unique`. A plain map, not an embedded
    # resource: each new constraint is then a validation rule, not a schema
    # change. Shape, type fit and regex safety are checked on save by
    # `Validations.FieldConstraints`; the value rules live in
    # `KilnCMS.CMS.FieldConstraints`, applied by `Changes.ApplyCustomFields`.
    attribute :validation, :map, allow_nil?: false, default: %{}, public?: true
    # Conditional rules (#2277), `KilnCMS.CMS.Conditions` JSON: the field is
    # hidden in the editor while `visible_when` is false, and required while
    # `required_when` is true. Both nil — always shown, `required` alone —
    # by default. Judged by `Validations.FieldCondition`, enforced on write by
    # `Changes.ApplyCustomFields`. Hidden is an editor concept, not a privacy
    # control: a hidden field's stored value stays in every read.
    attribute :visible_when, :map, public?: true
    attribute :required_when, :map, public?: true

    # Which records a `:reference` field may add (#2285),
    # `KilnCMS.CMS.ReferenceSelection` JSON: states, owner, sort and, per
    # target type, tags, category and custom-field equality. Nil — anything the
    # actor can read, as before — by default, and cleared on anything but a
    # top-level `:reference` (`Changes.ClearReferenceOptions`). Judged by
    # `Validations.ReferenceSelection`; enforced on add by
    # `Changes.ApplyCustomFields`. Not an access control: it narrows a read the
    # actor's policy already gates. Not carried by `JoinGraduation`.
    attribute :selection, :map, public?: true

    # Optional helper text rendered under the input.
    attribute :help_text, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # Display order within a content type's custom-field section.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # The heading this field is filed under in the content editor's Custom
    # fields panel ("Identity", "TCM properties", "Safety") — a type with a
    # hundred fields reads as a few collapsible sections rather than one long
    # scroll. Free text, shared by name: every field naming the same section
    # sits under one heading, which takes the place of its first field in
    # `position` order. `nil` files the field under no heading. Editor-only:
    # it changes nothing about the value, its delivery or its validation, and
    # the schema export reports it as `x-kiln-section`. Record-level fields
    # only — a link field or group sub-field sits inside its parent
    # (`Changes.ClearLinkFieldOptions`).
    attribute :section, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # How much of its section's row the field's input takes in the content
    # editor (#2280): the whole row (the default), half or a third — so short
    # inputs can sit side by side. Below the small breakpoint every field is
    # full width. Editor-only, like `section`; record-level fields only
    # (`Changes.ClearLinkFieldOptions`).
    #
    # Not `public?`, as `localization`: the JSON:API and GraphQL field schemas
    # stay what they were, and `KilnCMS.SchemaExport` reports a non-default
    # width as `x-kiln-width` instead.
    attribute :width, :atom do
      allow_nil? false
      default :full
      constraints one_of: [:full, :half, :third]
      public? false
    end

    # Whether this field's value is another *name* for the record — a Latin
    # name, a pinyin spelling, a trade name — so that a query containing it
    # finds the record the way a query containing the title does. Search's
    # alias leg (`KilnCMS.Search.hybrid/3`, `:search_alias`) phrase-matches
    # the query against every flagged field, and the per-type semantic
    # routes exempt a record so named from the relevance floor, exactly as
    # they do for its title. Text fields only in practice: the value is
    # matched as text, so a flag on a number or a media snapshot names
    # nothing.
    attribute :names_record, :boolean, allow_nil?: false, default: false, public?: true

    # Whether this field's value is indexed as body text (#1585): appended to
    # the record's `search_text` (`KilnCMS.CMS.SearchableFields`), so the
    # keyword legs find a record by a structured identity field — a Chinese
    # name, a Latin binomial — that its prose never repeats. Off by default:
    # most fields are numbers, enums and snapshots that would only add noise.
    # Independent of `names_record`, which makes the value a *name* (the
    # alias leg's phrase match) rather than body words. Flipping it, or
    # deleting a flagged field, re-fires the type's published documents
    # (`Changes.BustTypeRegistry`).
    attribute :searchable, :boolean, allow_nil?: false, default: false, public?: true

    # Whether delivery carries a plain-text rendition of this `:text` field's
    # value beside the stored one: `custom_fields_plain.<name>`, the value run
    # through `KilnCMS.PlainText.from_html/1`, for a client that cannot render
    # the HTML fragments an importer put there (a native app). Off by default,
    # so every existing payload is unchanged, and `custom_fields` itself is
    # never rewritten. `:text` only (`Changes.ClearDeliverPlain`). Flipping it
    # re-fires the type's published documents (`Changes.BustTypeRegistry`).
    attribute :deliver_plain, :boolean, allow_nil?: false, default: false, public?: true

    # Whether that plain rendition keeps the value's paragraph and line breaks
    # (`KilnCMS.PlainText.from_html_paragraphs/1`: a blank line between
    # paragraphs, a newline per `<br>` and list item) rather than reading as
    # one line. Same key, same string type — only the whitespace differs — so
    # off by default, and every field flagged before it existed keeps its
    # one-line value. Meaningful only with `deliver_plain`, and cleared
    # without it (`Changes.ClearDeliverPlain`). Flipping it re-fires the
    # type's published documents (`Changes.BustTypeRegistry`).
    attribute :plain_breaks, :boolean, allow_nil?: false, default: false, public?: true

    # Whether delivery carries a Portable Text rendition beside a rich `:text`
    # field's value: `custom_fields_portable.<name>`, the stored HTML as the
    # same tree a `rich_text` block's `body` delivers
    # (`KilnCMS.CMS.PortableFields`), for a native app that renders prose
    # without a browser engine. Off by default, so every existing payload is
    # unchanged; `custom_fields` itself is never rewritten. Top-level rich
    # `:text` only (`Changes.ClearDeliverPortable`). Flipping it re-fires the
    # type's published documents (`Changes.BustTypeRegistry`).
    attribute :deliver_portable, :boolean, allow_nil?: false, default: false, public?: true

    # Field-level localization (#1327): whether this field's value differs
    # between the locale variants of a document. `:localized` (the default) is
    # what every field has always done — each variant keeps its own value.
    # `:shared` keeps one value for the document: the default-locale variant
    # owns it, and publishing that variant copies it into every sibling
    # (`KilnCMS.I18n.SharedFields`). `:fallback` lets a variant leave the field
    # empty and inherit the value along the site's fallback chain at delivery
    # (`KilnCMS.I18n.FieldFallback`).
    #
    # Not `public?`: the JSON:API and GraphQL field schemas stay exactly what
    # they were for every site, and `KilnCMS.SchemaExport` reports a
    # non-default mode as `x-kiln-localization` instead.
    attribute :localization, :atom do
      allow_nil? false
      default :localized
      constraints one_of: [:localized, :shared, :fallback]
      public? false
    end

    # Optional default value (stored as a string, coerced to the field type when
    # an editor leaves the input blank).
    attribute :default, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    # A dynamic default (#2286): where a new record's value comes from when
    # the writer leaves the field blank, instead of the static `default`.
    # A closed set — `:today`, `:now`, `:current_user`, `:site_locale` and
    # `:copy_of` (another field of the same record, named by `default_field`);
    # no expression strings. Create-only (`Changes.ApplyCustomFields`); nil —
    # the static `default`, if any — is what every field had before.
    # `Changes.ClearDefaultSource` keeps it consistent with the type and with
    # `default`; `Validations.DefaultSource` judges `default_field`.
    attribute :default_source, :atom,
      public?: true,
      constraints: [one_of: [:today, :now, :current_user, :site_locale, :copy_of]]

    attribute :default_field, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # The formula behind a `:computed` field (#429) — a `KilnCMS.CMS.Computed`
    # template like `"{{ reading_time(body) }} min read"`, parsed and validated
    # on save by `Validations.ComputeExpression` and interpreted on every write
    # and every fire. Nil for every other field type.
    attribute :compute, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    # The dynamic type owning this field (nil for compiled-scoped fields).
    belongs_to :type_definition, KilnCMS.CMS.TypeDefinition do
      allow_nil? true
      public? true
    end

    # The `:reference` field owning this link field (R3) — nil for every
    # field of a content type.
    belongs_to :link_of, __MODULE__ do
      allow_nil? true
      public? true
    end

    # A `:reference` field's link fields — data on each connection it makes —
    # in editor order.
    has_many :link_fields, __MODULE__ do
      destination_attribute :link_of_id
      sort position: :asc, name: :asc
      public? true
    end

    # The `:group` field owning this sub-field — nil for every other field.
    belongs_to :group_of, __MODULE__ do
      allow_nil? true
      public? true
    end

    # A `:group` field's sub-fields — the keys of each object it holds — in
    # editor order. Includable through JSON:API
    # (`/type-definitions?include=field_definitions.group_fields`).
    has_many :group_fields, __MODULE__ do
      destination_attribute :group_of_id
      sort position: :asc, name: :asc
      public? true
    end
  end

  calculations do
    # The weight this field's text carries in the record's `search_vector`
    # (#2175 A3, `KilnCMS.CMS.Changes.SetSearchText`): `"A"`, the title's,
    # for a field that names the record; `"B"` for a searchable one — its
    # leading words, in extractor order, with whatever falls past the first
    # 48 of a record's searchable text at `"C"`; nil for a field search does
    # not index. The body is `"D"`. Derived from the two flags, so there is
    # nothing to set.
    calculate :search_weight,
              :string,
              expr(
                cond do
                  names_record -> "A"
                  searchable -> "B"
                  true -> nil
                end
              ) do
      public? true
    end
  end

  identities do
    # One field name per owner **per org** (Ash prepends `org_id`). Two
    # identities, one per scope — Postgres treats NULLs as distinct, so each acts
    # as a partial unique index over the rows where its scope column is set.
    identity :unique_field, [:content_type, :name]
    identity :unique_definition_field, [:type_definition_id, :name]
    identity :unique_link_field, [:link_of_id, :name]
    identity :unique_group_field, [:group_of_id, :name]
  end
end
