defmodule KilnCMS.CMS.FieldSync do
  @moduledoc """
  Config-sync for custom fields (#2288): export every `FieldDefinition` of a
  site (and the admin-defined `TypeDefinition`s that own some of them) to a
  versioned JSON document, and import such a document into another site or
  environment with a diff and a dry run first.

  Moving a model from staging to production used to mean redoing it by hand.
  This moves the *definitions* — never content. It runs through the same
  `FieldDefinition` / `TypeDefinition` actions an admin's click does, so every
  validation, change and policy applies (validation constraints, conditional
  rules, private fields, …), and **nothing here issues DDL**: fields are rows,
  and the schema changes of a release stay migrations.

  ## The document

      {
        "format": "kiln-field-definitions",
        "version": 1,
        "owners": [
          {"kind": "compiled", "type": "page", "fields": [ … ], "sections": [ … ]},
          {"kind": "dynamic", "type": "recipe", "definition": { … }, "fields": [ … ],
           "sections": [ … ]}
        ]
      }

  A field carries **every** attribute its create action accepts (the list is
  read from the action, so an attribute added later is covered without
  touching this module) except the four owner ids, which become the nesting:
  a `:reference` field holds its link fields under `"link_fields"`, a
  `:group` its sub-fields under `"group_fields"`. A key a hand-written file
  leaves out takes the attribute's default, so a file means the same thing to
  every environment. Role and membership field *grants* are not field
  attributes — they live on roles and are not part of this document.

  A reference field's `selection` (which records it may add, #2285) is **not**
  part of the document either: it names tag and category ids, which are per
  site, and fields of its target types that this import may not have created
  yet. An import neither writes it, changes it nor clears it, so what an
  environment configured survives; a file that carries a `"selection"` key is
  refused like any unknown key.

  An owner's `"sections"` lists how its sections are laid out in the editor
  (`KilnCMS.CMS.FieldSection`, #2280): `name`, `display` and `initially`, one
  entry per stored layout of a section some field of the owner carries. A
  section with no entry is the default accordion. The key is optional on
  import: an owner without it (a file written before layouts existed) leaves
  that owner's layouts as they are, even with `prune?: true`; an owner with
  it, `[]` included, declares all its layouts. A file this release writes
  cannot be imported by a release that predates #2280: every field carries
  `"width"`, a key such a release refuses as unknown.

  ## Import

  `import_doc/2` plans first: each field is a `:create`, an `:update` (with the
  attributes that differ), `:unchanged` or — only with `prune?: true` —
  `:delete`, matched by owner and name. A dry run (the default) also runs the
  whole apply inside a transaction it then rolls back, so a field the real run
  would refuse (a bad regex, a condition naming a missing sibling) is reported
  now. An apply is one transaction: any refusal writes nothing.

  Importing the same file twice changes nothing the second time.

  **Dropping data needs a flag.** A field that is deleted (a rename in the
  file is a delete plus a create), whose type changes, or that stops being a
  list while records hold a value under its name is *blocked*: nothing is
  written unless `allow_data_loss?: true`. The check is one existence query
  per such field; a link or group sub-field is judged by its parent's key.

  Types are never deleted or archived by an import, and without `prune?` a
  field absent from the file is left alone (and listed).

  Admin only: both directions need the actor to be able to define fields.
  """

  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.SyncFieldValues
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldSection
  alias KilnCMS.CMS.SectionLayouts
  alias KilnCMS.CMS.TypeDefinition
  alias KilnCMS.Repo

  @format "kiln-field-definitions"
  @version 1

  @owner_keys ~w(content_type type_definition_id link_of_id group_of_id)a
  # Attributes of a field that belong to one site and are not synced (#2285):
  # `selection` names tag and category ids, which differ per site, and fields
  # of its targets that this import may not have created yet.
  @site_keys ~w(selection)a
  @rules ~w(visible_when required_when)
  @child_lists [{"link_fields", :reference}, {"group_fields", :group}]
  @section_owner_keys ~w(content_type type_definition_id)a

  @type report :: map()

  @doc "The `format` marker of the document."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The document version this module writes and reads."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The field attributes a document carries (strings), read from the create
  action so a new attribute is covered automatically.
  """
  @spec field_keys() :: [String.t()]
  def field_keys do
    FieldDefinition
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Enum.reject(&(&1 in @owner_keys or &1 in @site_keys))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc """
  The section-layout attributes a document carries (strings), read from the
  `KilnCMS.CMS.FieldSection` create action like `field_keys/0`.
  """
  @spec section_keys() :: [String.t()]
  def section_keys do
    FieldSection
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Enum.reject(&(&1 in @section_owner_keys))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc "The dynamic-type attributes a document carries (strings)."
  @spec type_keys() :: [String.t()]
  def type_keys do
    TypeDefinition
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  # --- export ----------------------------------------------------------------

  @doc """
  The site's field definitions as a document map.

  Options: `actor:` (required, an admin), `tenant:` (the org).
  Fields of a compiled type that no longer exists (orphans) and of an archived
  dynamic type are left out.
  """
  @spec export(keyword()) :: {:ok, map()} | {:error, :forbidden}
  def export(opts) do
    scope = Keyword.take(opts, [:actor, :tenant])

    with :ok <- authorize(scope) do
      types = CMS.list_type_definitions!(scope)
      fields = CMS.list_field_definitions!(scope)
      sections = CMS.list_field_sections!(scope)

      children = Enum.group_by(fields, &FieldDefinition.parent_id/1)
      top = Enum.filter(fields, &is_nil(FieldDefinition.parent_id(&1)))

      compiled_sections = compiled_by_type(sections)

      compiled =
        top
        |> compiled_by_type()
        |> Enum.map(fn {type, fs} ->
          %{
            "kind" => "compiled",
            "type" => type,
            "fields" => field_docs(fs, children),
            "sections" => section_docs(Map.get(compiled_sections, type, []), fs)
          }
        end)

      dynamic =
        Enum.map(types, fn type ->
          fs = Enum.filter(top, &(&1.type_definition_id == type.id))

          %{
            "kind" => "dynamic",
            "type" => type.name,
            "definition" => attrs_doc(type, type_keys()),
            "fields" => field_docs(fs, children),
            "sections" =>
              sections |> Enum.filter(&(&1.type_definition_id == type.id)) |> section_docs(fs)
          }
        end)

      owners = Enum.sort_by(compiled ++ dynamic, &{&1["kind"], &1["type"]})
      {:ok, %{"format" => @format, "version" => @version, "owners" => owners}}
    end
  end

  # Rows of a compiled type that still exists, by its name. A field's and a
  # section's owner columns are the same, so `FieldDefinition.orphaned?/1`
  # judges both.
  defp compiled_by_type(rows) do
    rows
    |> Enum.reject(&(is_nil(&1.content_type) or FieldDefinition.orphaned?(&1)))
    |> Enum.group_by(&Atom.to_string(&1.content_type))
  end

  # Only the layouts of sections a field of the owner still carries: a row a
  # renamed or deleted section left behind lays nothing out.
  defp section_docs(sections, fields) do
    carried = MapSet.new(fields, & &1.section)

    sections
    |> Enum.filter(&MapSet.member?(carried, &1.name))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&attrs_doc(&1, section_keys()))
  end

  defp field_docs(fields, children) do
    fields
    |> Enum.sort_by(&{&1.position, &1.name})
    |> Enum.map(&field_doc(&1, children))
  end

  defp field_doc(field, children) do
    Enum.reduce(@child_lists, attrs_doc(field, field_keys()), fn {key, type}, acc ->
      subs = if field.field_type == type, do: Map.get(children, field.id, []), else: []
      if subs == [], do: acc, else: Map.put(acc, key, field_docs(subs, children))
    end)
  end

  defp attrs_doc(record, keys),
    do: Map.new(keys, fn key -> {key, jsonify(Map.get(record, String.to_existing_atom(key)))} end)

  @doc false
  def jsonify(nil), do: nil
  def jsonify(value) when is_boolean(value), do: value
  def jsonify(value) when is_atom(value), do: Atom.to_string(value)
  def jsonify(%{__struct__: _} = value), do: to_string(value)

  def jsonify(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), jsonify(v)} end)

  def jsonify(value) when is_list(value), do: Enum.map(value, &jsonify/1)
  def jsonify(value), do: value

  # --- import ----------------------------------------------------------------

  @doc """
  Plan, and optionally apply, a document. Returns `{:ok, report}`, or
  `{:error, report}` when the document is invalid, the plan is blocked, or a
  write was refused (`report.errors`, `report.blocked`); nothing is written in
  any `:error` case.

  Options: `actor:` (an admin), `tenant:`, `apply?:` (default `false` — a dry
  run), `prune?:` (delete fields absent from the file), `allow_data_loss?:`.
  """
  @spec import_doc(map(), keyword()) :: {:ok, report()} | {:error, :forbidden | report()}
  def import_doc(doc, opts) do
    scope = Keyword.take(opts, [:actor, :tenant])
    apply? = Keyword.get(opts, :apply?, false)
    prune? = Keyword.get(opts, :prune?, false)
    allow? = Keyword.get(opts, :allow_data_loss?, false)

    with :ok <- authorize(scope) do
      case parse(doc) do
        {:error, problems} -> {:error, invalid_report(problems, apply?)}
        {:ok, owners} -> plan_and_run(owners, scope, apply?, prune?, allow?)
      end
    end
  end

  defp invalid_report(problems, apply?) do
    errors = Enum.map(problems, &%{path: "document", messages: [&1]})
    %{empty_report(apply?) | errors: errors}
  end

  defp plan_and_run(owners, scope, apply?, prune?, allow?) do
    report = owners |> plan(scope, prune?) |> build_report(apply?)

    if report.blocked != [] and not allow?,
      do: {:error, report},
      else: execute(report, scope, apply?)
  end

  defp authorize(scope) do
    if CMS.can_create_field_definition?(scope[:actor], %{}, tenant: scope[:tenant]),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp empty_report(apply?),
    do: %{
      dry_run?: not apply?,
      applied?: false,
      ops: [],
      counts: %{},
      blocked: [],
      errors: [],
      untouched: []
    }

  # --- parsing ---------------------------------------------------------------

  defp parse(%{"format" => @format, "version" => @version, "owners" => owners})
       when is_list(owners) do
    {parsed, problems} =
      owners
      |> Enum.with_index()
      |> Enum.map(fn {owner, i} -> parse_owner(owner, "owners[#{i}]") end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    problems = Enum.flat_map(problems, fn {:error, list} -> list end)
    owners = Enum.map(parsed, fn {:ok, owner} -> owner end)

    problems = problems ++ duplicate_owners(owners)

    if problems == [], do: {:ok, owners}, else: {:error, problems}
  end

  defp parse(%{"format" => @format, "version" => version}),
    do:
      {:error,
       ["unsupported document version #{inspect(version)} (this release reads #{@version})"]}

  defp parse(_other), do: {:error, ["not a #{@format} document"]}

  defp duplicate_owners(owners) do
    owners
    |> Enum.frequencies_by(&{&1.kind, &1.type})
    |> Enum.filter(fn {_key, n} -> n > 1 end)
    |> Enum.map(fn {{kind, type}, _n} -> "#{kind} type #{inspect(type)} appears twice" end)
  end

  defp parse_owner(%{"kind" => kind, "type" => type, "fields" => fields} = owner, path)
       when kind in ["compiled", "dynamic"] and is_binary(type) and is_list(fields) do
    {def_result, def_problems} = parse_definition(kind, owner["definition"], path)
    {fields, problems} = parse_fields(fields, "#{path}.#{type}", [])
    {sections, section_problems} = parse_sections(owner["sections"], "#{path}.#{type}")

    case def_problems ++ problems ++ section_problems do
      [] ->
        {:ok,
         %{kind: kind, type: type, definition: def_result, fields: fields, sections: sections}}

      list ->
        {:error, list}
    end
  end

  defp parse_owner(_other, path),
    do: {:error, ["#{path}: needs \"kind\" (compiled | dynamic), \"type\" and a \"fields\" list"]}

  defp parse_definition("compiled", nil, _path), do: {nil, []}

  defp parse_definition("compiled", _def, path),
    do: {nil, ["#{path}: a compiled type has no \"definition\""]}

  defp parse_definition("dynamic", nil, _path), do: {nil, []}

  defp parse_definition("dynamic", %{} = definition, path) do
    case Map.keys(definition) -- type_keys() do
      [] -> {fill(definition, TypeDefinition, type_keys()), []}
      unknown -> {nil, ["#{path}.definition: unknown key(s) #{Enum.join(unknown, ", ")}"]}
    end
  end

  defp parse_definition(_kind, _def, path),
    do: {nil, ["#{path}: \"definition\" must be an object"]}

  defp parse_fields(fields, path, _acc) do
    results = Enum.map(fields, &parse_field(&1, path))

    names =
      for {:ok, f} <- results, do: f["name"]

    dups =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_n, c} -> c > 1 end)
      |> Enum.map(fn {n, _} -> "#{path}: field #{inspect(n)} appears twice" end)

    problems =
      Enum.flat_map(results, fn
        {:error, list} -> list
        _ -> []
      end) ++ dups

    {for({:ok, f} <- results, do: f), problems}
  end

  defp parse_field(%{} = field, path) do
    name = field["name"]
    here = if is_binary(name), do: "#{path}.#{name}", else: "#{path}.?"
    child_keys = Enum.map(@child_lists, &elem(&1, 0))
    unknown = Map.keys(field) -- (field_keys() ++ child_keys)

    cond do
      not is_binary(name) or not is_binary(field["label"]) ->
        {:error, ["#{here}: \"name\" and \"label\" are required"]}

      unknown != [] ->
        {:error, ["#{here}: unknown key(s) #{Enum.join(unknown, ", ")}"]}

      true ->
        parse_children(
          fill(Map.drop(field, child_keys), FieldDefinition, field_keys()),
          field,
          here
        )
    end
  end

  defp parse_field(_other, path), do: {:error, ["#{path}: a field must be an object"]}

  defp parse_children(attrs, field, here) do
    results =
      for {key, type} <- @child_lists, Map.has_key?(field, key) do
        cond do
          attrs["field_type"] != Atom.to_string(type) ->
            {key, {:error, ["#{here}: \"#{key}\" only belongs to a #{type} field"]}}

          not is_list(field[key]) ->
            {key, {:error, ["#{here}: \"#{key}\" must be a list"]}}

          true ->
            {subs, problems} = parse_fields(field[key], here, [])
            {key, if(problems == [], do: {:ok, subs}, else: {:error, problems})}
        end
      end

    case Enum.flat_map(results, fn
           {_k, {:error, p}} -> p
           _ -> []
         end) do
      [] ->
        {:ok, Enum.reduce(results, attrs, fn {k, {:ok, subs}}, acc -> Map.put(acc, k, subs) end)}

      problems ->
        {:error, problems}
    end
  end

  # No `"sections"` key: a file from before layouts existed. It says nothing
  # about them, so the import leaves them alone (`nil`, not `[]`).
  defp parse_sections(nil, _path), do: {nil, []}

  defp parse_sections(sections, path) when is_list(sections) do
    results = Enum.map(sections, &parse_section(&1, "#{path}.sections"))
    parsed = for {:ok, section} <- results, do: section

    dups =
      parsed
      |> Enum.frequencies_by(& &1["name"])
      |> Enum.filter(fn {_name, n} -> n > 1 end)
      |> Enum.map(fn {name, _n} -> "#{path}.sections: section #{inspect(name)} appears twice" end)

    {parsed, Enum.flat_map(results, &section_problems/1) ++ dups}
  end

  defp parse_sections(_other, path), do: {[], ["#{path}: \"sections\" must be a list"]}

  defp section_problems({:error, problems}), do: problems
  defp section_problems({:ok, _section}), do: []

  defp parse_section(%{"name" => name} = section, path) when is_binary(name) do
    case Map.keys(section) -- section_keys() do
      [] -> {:ok, fill(section, FieldSection, section_keys())}
      unknown -> {:error, ["#{path}.#{name}: unknown key(s) #{Enum.join(unknown, ", ")}"]}
    end
  end

  defp parse_section(_other, path),
    do: {:error, ["#{path}: a section must be an object with a \"name\""]}

  # A key the file leaves out takes the attribute's default.
  defp fill(map, resource, keys) do
    Map.new(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {key, jsonify(value)}
        :error -> {key, jsonify(default(resource, key))}
      end
    end)
  end

  defp default(resource, key) do
    case Ash.Resource.Info.attribute(resource, String.to_existing_atom(key)) do
      %{default: fun} when is_function(fun, 0) -> fun.()
      %{default: {m, f, a}} -> apply(m, f, a)
      %{default: value} -> value
      nil -> nil
    end
  end

  # --- planning --------------------------------------------------------------

  # One op per row, parents before children. `existing` is the stored record.
  defp plan(owners, scope, prune?) do
    types = Map.new(CMS.list_type_definitions!(scope), &{&1.name, &1})
    fields = CMS.list_field_definitions!(scope)
    sections = CMS.list_field_sections!(scope)
    by_children = Enum.group_by(fields, &FieldDefinition.parent_id/1)

    type_ops = Enum.flat_map(owners, &type_op(&1, types))

    field_ops =
      Enum.flat_map(owners, fn owner ->
        existing = existing_top(owner, types, fields)
        top = field_ops(owner.fields, existing, by_children, "#{owner.type}", [], prune?)
        top
      end)

    section_ops =
      Enum.flat_map(owners, fn owner ->
        section_ops(owner, existing_owned(owner, types, sections), prune?)
      end)

    type_ops ++ field_ops ++ section_ops
  end

  # An owner without a `"sections"` key declares no layouts: none is touched.
  defp section_ops(%{sections: nil}, _existing, _prune?), do: []

  # Matched by name within the owner, as fields are. The path cannot collide
  # with a field's: a field name never holds a `/`.
  defp section_ops(owner, existing, prune?) do
    by_name = Map.new(existing, &{&1.name, &1})
    file_names = MapSet.new(owner.sections, & &1["name"])
    path = &"#{owner.type}/section/#{&1}"
    keys = section_keys() -- ["name"]

    present =
      for section <- owner.sections do
        here = path.(section["name"])

        case Map.get(by_name, section["name"]) do
          nil ->
            %{
              op: :create,
              kind: :section,
              path: here,
              attrs: section,
              changes: %{},
              existing: nil
            }

          record ->
            op_for(:section, here, section, record, diff(record, section, keys))
        end
        |> Map.put(:owner, owner.type)
      end

    extra =
      for record <- existing, not MapSet.member?(file_names, record.name) do
        %{
          op: if(prune?, do: :delete, else: :untouched),
          kind: :section,
          path: path.(record.name),
          attrs: nil,
          changes: %{},
          existing: record,
          owner: owner.type
        }
      end

    present ++ extra
  end

  defp type_op(%{kind: "dynamic", definition: %{} = definition, type: type}, types) do
    path = "type:#{type}"

    case Map.get(types, type) do
      nil ->
        [%{op: :create, kind: :type, path: path, attrs: definition, changes: %{}, existing: nil}]

      existing ->
        changes = diff(existing, Map.delete(definition, "name"), type_keys() -- ["name"])
        [op_for(:type, path, definition, existing, changes)]
    end
  end

  defp type_op(_owner, _types), do: []

  defp existing_top(owner, types, fields),
    do: existing_owned(owner, types, Enum.filter(fields, &is_nil(FieldDefinition.parent_id(&1))))

  # The stored rows (fields or section layouts) the owner holds.
  defp existing_owned(%{kind: "compiled", type: type}, _types, rows) do
    for row <- rows,
        is_atom(row.content_type) and not is_nil(row.content_type),
        Atom.to_string(row.content_type) == type,
        do: row
  end

  defp existing_owned(%{kind: "dynamic", type: type}, types, rows) do
    case Map.get(types, type) do
      nil -> []
      %{id: id} -> for row <- rows, row.type_definition_id == id, do: row
    end
  end

  defp field_ops(file_fields, existing, children_of, path, parent_ctx, prune?) do
    by_name = Map.new(existing, &{&1.name, &1})
    file_names = MapSet.new(file_fields, & &1["name"])

    present =
      Enum.flat_map(file_fields, fn field ->
        here = "#{path}.#{field["name"]}"
        record = Map.get(by_name, field["name"])
        attrs = Map.drop(field, Enum.map(@child_lists, &elem(&1, 0)))

        own =
          case record do
            nil ->
              %{
                op: :create,
                kind: :field,
                path: here,
                attrs: attrs,
                changes: %{},
                existing: nil,
                parent: parent_ctx
              }

            record ->
              changes = diff(record, attrs, field_keys())
              op_for(:field, here, attrs, record, changes) |> Map.put(:parent, parent_ctx)
          end

        subs =
          Enum.flat_map(@child_lists, &child_ops(&1, field, record, here, children_of, prune?))

        [own | subs]
      end)

    extra =
      for record <- existing, not MapSet.member?(file_names, record.name) do
        %{
          op: if(prune?, do: :delete, else: :untouched),
          kind: :field,
          path: "#{path}.#{record.name}",
          attrs: nil,
          changes: %{},
          existing: record,
          parent: parent_ctx
        }
      end

    present ++ extra
  end

  defp child_ops({key, _type}, field, record, here, children_of, prune?) do
    kids = Map.get(field, key, [])

    existing_kids =
      if record,
        do: children_of |> Map.get(record.id, []) |> Enum.filter(&kid_of?(&1, key)),
        else: []

    if kids == [] and existing_kids == [],
      do: [],
      else: field_ops(kids, existing_kids, children_of, here, {key, here}, prune?)
  end

  defp kid_of?(%{link_of_id: id}, "link_fields"), do: not is_nil(id)
  defp kid_of?(%{group_of_id: id}, "group_fields"), do: not is_nil(id)
  defp kid_of?(_kid, _key), do: false

  defp op_for(kind, path, attrs, record, changes) do
    %{
      op: if(changes == %{}, do: :unchanged, else: :update),
      kind: kind,
      path: path,
      attrs: attrs,
      changes: changes,
      existing: record
    }
  end

  defp diff(record, attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      current = jsonify(Map.get(record, String.to_existing_atom(key)))

      if Map.has_key?(attrs, key) and current != attrs[key],
        do: Map.put(acc, key, {current, attrs[key]}),
        else: acc
    end)
  end

  # --- report ----------------------------------------------------------------

  defp build_report(ops, apply?) do
    ops = Enum.map(ops, &guard/1)
    counts = Enum.frequencies_by(ops, & &1.op)

    # A deleted parent takes its children along; their own rows are not
    # reported as separate deletions of data.
    blocked =
      for %{blocked: reason} = op <- ops, reason, do: %{path: op.path, reason: reason}

    %{
      dry_run?: not apply?,
      applied?: false,
      ops: ops,
      counts: counts,
      blocked: blocked,
      errors: [],
      untouched: for(op <- ops, op.op == :untouched, do: op.path)
    }
  end

  # Does this op drop values a record holds?
  defp guard(op), do: Map.put(op, :blocked, data_loss(op))

  # A layout holds no values.
  defp data_loss(%{kind: :section}), do: nil

  defp data_loss(%{op: :delete, existing: record}),
    do: if(holds_data?(record), do: "deleting it drops the values records hold", else: nil)

  defp data_loss(%{op: :update, existing: record, changes: changes}) do
    cond do
      Map.has_key?(changes, "field_type") and holds_data?(record) ->
        "changing its type leaves the stored values in the wrong shape"

      match?({true, false}, changes["multiple"]) and holds_data?(record) ->
        "it stops being a list, so each record keeps only its first item"

      true ->
        nil
    end
  end

  defp data_loss(_op), do: nil

  # Records hold a value under the field's key (a sub-field: under its
  # parent's). An orphaned or unresolvable owner holds none we can reach.
  # sobelow_skip ["SQL.Query"]
  defp holds_data?(record) do
    record = governing(record)

    case SyncFieldValues.target(record) do
      {:ok, table, filter, params} ->
        sql =
          "SELECT EXISTS (SELECT 1 FROM #{table} " <>
            "WHERE custom_fields ? $1 AND custom_fields -> $1 <> 'null'::jsonb#{filter.(1)})"

        case Repo.query(sql, [record.name | params]) do
          {:ok, %{rows: [[true]]}} -> true
          _none -> false
        end

      :error ->
        false
    end
  end

  defp governing(%{link_of_id: id} = record) when not is_nil(id), do: parent_record(record, id)
  defp governing(%{group_of_id: id} = record) when not is_nil(id), do: parent_record(record, id)
  defp governing(record), do: record

  defp parent_record(record, parent_id) do
    case CMS.get_field_definition(parent_id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: record.org_id
         ) do
      {:ok, parent} -> parent
      _missing -> record
    end
  end

  # --- applying --------------------------------------------------------------

  defp execute(report, scope, apply?) do
    result =
      AfterCommit.deferring(fn ->
        Repo.transaction(fn -> in_transaction(report, scope, apply?) end)
      end)

    case result do
      {:ok, _ids} ->
        {:ok, %{report | applied?: true}}

      {:error, :dry_run} ->
        {:ok, report}

      {:error, {:errors, errors}} ->
        {:error, %{report | errors: errors}}

      # An Ash action that fails inside our transaction aborts the whole of
      # it and surfaces its own error here, not through `Repo.rollback/1`.
      {:error, error} ->
        path = Process.get({__MODULE__, :current}, "document")
        {:error, %{report | errors: [%{path: path, messages: messages(error)}]}}
    end
  end

  defp in_transaction(report, scope, apply?) do
    case run_ops(report.ops, scope) do
      {:ok, ids} when apply? -> ids
      {:ok, _ids} -> Repo.rollback(:dry_run)
      {:error, errors} -> Repo.rollback({:errors, errors})
    end
  end

  defp run_ops(ops, scope) do
    opts = [actor: scope[:actor], tenant: scope[:tenant], context: AfterCommit.context()]
    # Everything stored already, so a new field can find its stored owner.
    ids =
      for %{existing: existing, path: path} when not is_nil(existing) <- ops,
          into: %{},
          do: {path, existing}

    with {:ok, ids} <- run_phase(ops, :types, ids, opts),
         {:ok, ids} <- run_phase(ops, :sections, ids, opts),
         {:ok, ids} <- run_phase(ops, :fields, ids, opts),
         {:ok, ids} <- run_phase(ops, :rules, ids, opts),
         {:ok, ids} <- run_phase(ops, :deletes, ids, opts) do
      drop_section_layouts(ops, ids, opts)
    end
  end

  # A deleted field that was the last of its section takes the section's
  # layout with it, as a delete in the fields admin does. Read after every
  # delete has run, so a section op's own delete is already done.
  defp drop_section_layouts(ops, ids, opts) do
    ops
    |> Enum.filter(
      &match?(%{kind: :field, op: :delete, existing: %{section: s}} when is_binary(s), &1)
    )
    |> Enum.flat_map(fn %{existing: record} ->
      case SectionLayouts.owner_of(record) do
        nil -> []
        owner -> [{owner, record.section}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while({:ok, ids}, fn {owner, names}, {:ok, ids} ->
      case SectionLayouts.prune(owner, [only: names] ++ opts) do
        :ok -> {:cont, {:ok, ids}}
        {:error, error} -> {:halt, {:error, [%{path: "sections", messages: messages(error)}]}}
      end
    end)
  end

  defp run_phase(ops, phase, ids, opts) do
    ops
    |> Enum.filter(&in_phase?(&1, phase))
    |> order(phase)
    |> Enum.reduce_while({:ok, ids}, fn op, {:ok, ids} ->
      Process.put({__MODULE__, :current}, op.path)

      case run_op(op, phase, ids, opts) do
        {:ok, ids} -> {:cont, {:ok, ids}}
        {:error, error} -> {:halt, {:error, [%{path: op.path, messages: messages(error)}]}}
      end
    end)
  end

  # A field other fields' rules read cannot go first: delete the readers.
  defp order(ops, :deletes),
    do:
      Enum.sort_by(
        ops,
        &(is_nil(Map.get(&1.existing, :visible_when)) and
            is_nil(Map.get(&1.existing, :required_when)))
      )

  defp order(ops, _phase), do: ops

  defp in_phase?(%{kind: :type, op: op}, :types), do: op in [:create, :update]
  defp in_phase?(%{kind: :section, op: op}, :sections), do: op in [:create, :update]
  defp in_phase?(%{kind: :section, op: :delete}, :deletes), do: true
  defp in_phase?(%{kind: :field, op: op}, :fields), do: op in [:create, :update]
  defp in_phase?(%{kind: :field, op: op} = o, :rules), do: op in [:create, :update] and rules?(o)
  defp in_phase?(%{kind: :field, op: :delete}, :deletes), do: true
  defp in_phase?(_op, _phase), do: false

  defp rules?(%{op: :create, attrs: attrs}), do: Enum.any?(@rules, &(attrs[&1] != nil))
  defp rules?(%{op: :update, changes: changes}), do: Enum.any?(@rules, &Map.has_key?(changes, &1))

  defp run_op(%{kind: :type, op: :create, attrs: attrs, path: path}, :types, ids, opts) do
    with {:ok, type} <- CMS.create_type_definition(attrs, opts) do
      {:ok, Map.put(ids, path, type)}
    end
  end

  defp run_op(
         %{kind: :type, op: :update, existing: existing, changes: changes, path: path},
         :types,
         ids,
         opts
       ) do
    with {:ok, type} <- CMS.update_type_definition(existing, wanted(changes), opts) do
      {:ok, Map.put(ids, path, type)}
    end
  end

  defp run_op(%{kind: :field, op: :create} = op, :fields, ids, opts) do
    with {:ok, scope_ids} <- owner_ids(op, ids),
         attrs = op.attrs |> Map.drop(@rules) |> Map.merge(scope_ids),
         {:ok, field} <- CMS.create_field_definition(attrs, opts) do
      {:ok, Map.put(ids, op.path, field)}
    end
  end

  defp run_op(
         %{kind: :field, op: :update, existing: record, changes: changes} = op,
         :fields,
         ids,
         opts
       ) do
    case changes |> Map.drop(@rules) |> wanted() do
      empty when empty == %{} ->
        {:ok, Map.put(ids, op.path, record)}

      params ->
        params = with_widget(params, op.attrs)

        with {:ok, field} <- CMS.update_field_definition(record, params, opts) do
          {:ok, Map.put(ids, op.path, field)}
        end
    end
  end

  defp run_op(%{kind: :field} = op, :rules, ids, opts) do
    record = Map.get(ids, op.path) || op.existing
    params = Map.new(@rules, &{&1, op.attrs[&1]})

    with {:ok, field} <- CMS.update_field_definition(record, params, opts) do
      {:ok, Map.put(ids, op.path, field)}
    end
  end

  defp run_op(
         %{kind: :section, op: :create, attrs: attrs, owner: type} = op,
         :sections,
         ids,
         opts
       ) do
    owner =
      case Map.get(ids, "type:#{type}") do
        %{id: id} -> %{"type_definition_id" => id}
        nil -> %{"content_type" => type}
      end

    with {:ok, section} <- CMS.create_field_section(Map.merge(attrs, owner), opts) do
      {:ok, Map.put(ids, op.path, section)}
    end
  end

  defp run_op(%{kind: :section, op: :update, existing: record} = op, :sections, ids, opts) do
    with {:ok, section} <- CMS.update_field_section(record, wanted(op.changes), opts) do
      {:ok, Map.put(ids, op.path, section)}
    end
  end

  defp run_op(%{kind: :section, op: :delete, existing: record}, :deletes, ids, opts) do
    with :ok <- CMS.destroy_field_section(record, opts), do: {:ok, ids}
  end

  defp run_op(%{kind: :field, op: :delete, existing: record}, :deletes, ids, opts) do
    # A parent's delete cascades to its children; they may already be gone.
    case CMS.get_field_definition(record.id, Keyword.take(opts, [:actor, :tenant])) do
      {:ok, current} ->
        with :ok <- CMS.destroy_field_definition(current, opts), do: {:ok, ids}

      _gone ->
        {:ok, ids}
    end
  end

  defp wanted(changes), do: Map.new(changes, fn {key, {_from, to}} -> {key, to} end)

  # The file's editor widget (#2284) goes with every update of its field,
  # even when it equals the stored one: left out, a change the widget no
  # longer suits (`multiple` on a radios select) would silently clear it
  # (`Changes.ClearWidget`) instead of being refused, and the next import
  # would see the file and the site disagree again.
  defp with_widget(params, attrs) do
    case Map.fetch(attrs, "widget") do
      {:ok, widget} -> Map.put_new(params, "widget", widget)
      :error -> params
    end
  end

  # The ids that tie a new field to its owner, resolved from what the earlier
  # ops created (or the stored owner).
  defp owner_ids(%{parent: {key, parent_path}}, ids) do
    case Map.get(ids, parent_path) do
      nil ->
        {:error, "its parent field #{parent_path} was not found"}

      parent ->
        {:ok, %{if(key == "link_fields", do: "link_of_id", else: "group_of_id") => parent.id}}
    end
  end

  defp owner_ids(%{path: path}, ids) do
    type = path |> String.split(".") |> hd()

    case Map.get(ids, "type:#{type}") do
      %{id: id} -> {:ok, %{"type_definition_id" => id}}
      nil -> {:ok, %{"content_type" => type}}
    end
  end

  defp messages(error) when is_binary(error), do: [error]

  defp messages(%{errors: errors}) when is_list(errors),
    do: Enum.map(errors, &Exception.message/1)

  defp messages(error), do: [Exception.message(error)]

  # --- text ------------------------------------------------------------------

  @doc "A plain-text rendering of a report: the diff, then what blocked or failed."
  @spec describe(report()) :: String.t()
  def describe(report) do
    lines =
      for op <- report.ops, op.op != :unchanged do
        line(op)
      end

    counts = report.counts

    summary =
      "#{Map.get(counts, :create, 0)} to create, #{Map.get(counts, :update, 0)} to update, " <>
        "#{Map.get(counts, :delete, 0)} to delete, #{Map.get(counts, :unchanged, 0)} unchanged" <>
        if(report.untouched == [],
          do: "",
          else: ", #{length(report.untouched)} not in the file (kept)"
        )

    blocked =
      for %{path: path, reason: reason} <- report.blocked, do: "BLOCKED #{path}: #{reason}"

    errors =
      for %{path: path, messages: ms} <- report.errors,
          do: "ERROR #{path}: #{Enum.join(ms, "; ")}"

    Enum.join(lines ++ [summary] ++ blocked ++ errors, "\n")
  end

  defp line(%{op: :create, kind: :section, path: path, attrs: attrs}),
    do: "+ #{path} (#{attrs["display"]})"

  defp line(%{op: :create, path: path, attrs: attrs}),
    do: "+ #{path} (#{attrs["field_type"] || "type"})"

  defp line(%{op: :update, path: path, changes: changes}),
    do: "~ #{path}: #{changes |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"

  defp line(%{op: :delete, path: path}), do: "- #{path}"
  defp line(%{op: :untouched, path: path}), do: "? #{path} (not in the file)"

  # --- command line glue (mix tasks and the release) ---------------------------

  @shell_opts [:actor, :org, :out, :apply, :prune, :allow_data_loss]

  @doc "`mix kiln.fields.export` for both the task and the release."
  @spec export_file(Path.t() | nil, keyword(), (String.t() -> any())) ::
          {:ok, map()} | {:error, String.t()}
  def export_file(path, opts, shell) do
    with {:ok, opts} <- known(opts),
         {:ok, scope} <- KilnCMS.Portability.CLI.scope(opts, shell),
         {:ok, doc} <- export(scope) |> forbidden() do
      json = Jason.encode!(doc, pretty: true)

      if path do
        write(path, json)
        shell.("Wrote #{count(doc)} field definition(s) to #{path}")
      else
        shell.(json)
      end

      {:ok, doc}
    end
  end

  @doc "`mix kiln.fields.import` for both the task and the release."
  @spec import_file(Path.t(), keyword(), (String.t() -> any())) ::
          {:ok, report()} | {:error, String.t()}
  def import_file(path, opts, shell) do
    with {:ok, opts} <- known(opts),
         {:ok, doc} <- read(path),
         {:ok, scope} <- KilnCMS.Portability.CLI.scope(opts, shell) do
      run_opts =
        scope ++
          [
            apply?: Keyword.get(opts, :apply, false) == true,
            prune?: Keyword.get(opts, :prune, false) == true,
            allow_data_loss?: Keyword.get(opts, :allow_data_loss, false) == true
          ]

      report_import(import_doc(doc, run_opts), shell)
    end
  end

  defp report_import({:ok, report}, shell) do
    shell.(
      if(report.applied?,
        do: "── APPLIED ──",
        else: "── DRY RUN — nothing was written ──"
      )
    )

    shell.(describe(report))
    {:ok, report}
  end

  defp report_import({:error, :forbidden}, _shell),
    do: {:error, "That user cannot define fields (admin only)."}

  defp report_import({:error, report}, shell) do
    shell.(describe(report))

    {:error,
     "Nothing was written. Fix the problems above, or pass --allow-data-loss for a blocked change."}
  end

  defp known(opts) do
    case Keyword.keys(opts) -- @shell_opts do
      [] ->
        {:ok, opts}

      unknown ->
        {:error, "Unknown option(s) #{Enum.map_join(Enum.uniq(unknown), ", ", &inspect/1)}"}
    end
  end

  defp forbidden({:error, :forbidden}),
    do: {:error, "That user cannot define fields (admin only)."}

  defp forbidden(other), do: other

  defp count(doc), do: doc["owners"] |> Enum.map(&length(&1["fields"])) |> Enum.sum()

  # The path is the operator's own argument.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, json), do: File.write!(path, json)

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    with {:ok, json} <- File.read(path),
         {:ok, doc} <- Jason.decode(json) do
      {:ok, doc}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{path} is not valid JSON: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end
end
