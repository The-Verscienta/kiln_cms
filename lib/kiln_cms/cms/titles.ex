defmodule KilnCMS.CMS.Titles do
  @moduledoc """
  Computed record titles (#2287): a content type's optional `title_template`
  builds each record's `title` from its other fields on save, the way Drupal's
  Automatic Entity Label does.

  The template is the computed-field language (`KilnCMS.CMS.Computed`), so
  there is one syntax to learn and one evaluator to trust:

      {{ field.last_name }}, {{ field.first_name }} ({{ field.city }})

  `derive/2` evaluates a template against a context built by
  `changeset_context/1` (or `record_context/2` for a stored row) and answers
  `{:ok, title}` — trimmed and cut to the title's own length limit — or
  `:blank` when the template yields nothing (every referenced field empty).
  What a blank result means is the caller's call (`Changes.DeriveTitle`).

  ## What a template may read

  Custom fields and the document scalars, **except `title` and `slug`**: the
  title is what the template produces, and the slug derives from the title, so
  either reference would be a cycle. `validate/2` refuses both — directly, and
  through a computed field that reads them — as well as a private field
  (#2044; the title is public) and, for a dynamic type, a field the type does
  not define. A compiled type's definitions live in the registry, not in the
  `use` line, so for those only the syntax and the title/slug rule are
  checked at build time.

  Because private fields never enter the context, a field a restricted editor
  may not read (a subset of the private ones, `KilnCMS.CMS.HiddenFields`) can
  never reach a title either.

  A template is stored on `TypeDefinition.title_template` for dynamic types and
  declared as `use KilnCMS.CMS.Content, title_template: "..."` for compiled
  ones (`__kiln_content_title_template__/0`).
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.CMS.Computed
  alias KilnCMS.CMS.Computed.Context

  @marker :__kiln_content_title_template__

  # The document scalars a title template must not read: the title itself, and
  # the slug that is derived from it.
  @cyclic ["title", "slug"]

  @doc "The template's length limit, in characters (the column's constraint)."
  @spec max_length() :: pos_integer()
  def max_length, do: 500

  # --- derivation -------------------------------------------------------------

  @doc """
  Evaluate `template` against `context` (the `KilnCMS.CMS.Computed` shape).

  `{:ok, title}` when it yields text, `:blank` when it yields nothing. The
  result is trimmed and cut to `KilnCMS.Limits.line/0` characters, the title
  column's own limit — a template over long fields must not fail the save it
  is decorating.
  """
  @spec derive(String.t() | nil, map()) :: {:ok, String.t()} | :blank
  def derive(nil, _context), do: :blank

  def derive(template, context) when is_binary(template) do
    case template |> Computed.evaluate(context) |> text() do
      "" -> :blank
      title -> {:ok, String.slice(title, 0, KilnCMS.Limits.line())}
    end
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  # nil, and a structured value that has no single-line rendering.
  defp text(_other), do: ""

  # --- which template applies -------------------------------------------------

  @doc """
  The title template of the content type `changeset` writes, with the
  changeset carrying what was read: a compiled type's marker (no read), else —
  for the dynamic entry tier — its `TypeDefinition`, read once and stashed in
  the changeset context (`Slugs.pattern_for/2` reuses it). `nil` when the type
  has no template.
  """
  @spec template_for(Ash.Changeset.t()) :: {String.t() | nil, Ash.Changeset.t()}
  def template_for(%Ash.Changeset{resource: resource} = changeset) do
    if Code.ensure_loaded?(resource) and function_exported?(resource, @marker, 0) do
      {apply(resource, @marker, []), changeset}
    else
      case type_definition(changeset) do
        {nil, changeset} -> {nil, changeset}
        {definition, changeset} -> {definition.title_template, changeset}
      end
    end
  end

  defp type_definition(changeset) do
    with id when not is_nil(id) <-
           KilnCMS.CMS.Slugs.changeset_attribute(changeset, :type_definition_id),
         {:ok, definition} <- fetch_definition(changeset, id) do
      {definition, Ash.Changeset.set_context(changeset, %{kiln_type_definition: definition})}
    else
      _ -> {nil, changeset}
    end
  end

  defp fetch_definition(changeset, id) do
    case changeset.context do
      %{kiln_type_definition: %{id: ^id} = definition} ->
        {:ok, definition}

      _ ->
        id
        |> KilnCMS.CMS.get_type_definition(registry_opts(changeset.tenant))
        |> raise_if_forbidden()
    end
  end

  # Registry reads run as the system and fail closed, exactly as
  # `Slugs.pattern_for/2` does: a refusal that read as "no template" would
  # leave a hand-typed title on a record whose type derives them.
  defp registry_opts(tenant) do
    [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: tenant
    ]
  end

  defp raise_if_forbidden({:error, %Ash.Error.Forbidden{} = error}), do: raise(error)
  defp raise_if_forbidden(result), do: result

  # --- contexts ---------------------------------------------------------------

  @doc """
  The evaluation context for a write: the document scalars as the changeset
  holds them and the custom fields the write will store.

  The fields are `custom_fields` when given (the working copy's held map), else
  the stored map with the payload merged over it (a partial update keeps the
  keys it does not mention) — minus the type's private fields, plus every
  computed field derived fresh, the view `[field:…]` slug tokens get
  (`Slugs.effective_custom_fields/2`). Computed fields are only derived when
  the template reads a custom field at all.
  """
  @spec changeset_context(Ash.Changeset.t(), String.t(), map() | nil) :: map()
  def changeset_context(changeset, template, custom_fields \\ nil) do
    changeset = Context.pin_today(changeset)
    computed? = Computed.references(template) != []

    fields =
      if is_map(custom_fields),
        do: KilnCMS.CMS.Slugs.public_custom_fields(changeset, custom_fields, computed?),
        else: KilnCMS.CMS.Slugs.effective_custom_fields(changeset, computed?)

    Context.from_changeset(changeset, fields)
  end

  @doc """
  The evaluation context for a stored `record` (the sweep, `mix
  kiln.titles.regenerate`): its own `custom_fields`, private ones dropped,
  computed ones re-derived from `definitions`.
  """
  @spec record_context(struct(), [struct()]) :: map()
  def record_context(record, definitions) do
    raw =
      record
      |> Map.get(:custom_fields)
      |> Kernel.||(%{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> KilnCMS.CMS.PrivateFields.drop_for(record)

    computed = Enum.filter(definitions, &(&1.field_type == :computed))
    today = Context.today()
    base = Context.from_document(record, Map.drop(raw, Enum.map(computed, & &1.name)), today)

    %{base | fields: Computed.derive(computed, base, base.fields)}
  end

  # --- definition-time validation ---------------------------------------------

  @doc """
  Check a template at definition time. `:ok`, or `{:error, message}` with a
  human-readable reason.

  Options:

    * `:definitions` — the type's `FieldDefinition` rows. When given, a
      reference to a field the type does not define, or to a private one, is
      refused. Omit it for a compiled type, whose definitions are not known at
      build time.
  """
  @spec validate(String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def validate(nil, _opts), do: :ok

  def validate(template, opts) when is_binary(template) do
    cond do
      String.trim(template) == "" ->
        :ok

      String.length(template) > max_length() ->
        {:error, gettext("is too long (at most %{count} characters)", count: max_length())}

      true ->
        case Computed.parse(template) do
          {:ok, parsed} ->
            check_references(parsed, Keyword.get(opts, :definitions))

          {:error, message} ->
            {:error, gettext("isn't a valid template: %{message}", message: message)}
        end
    end
  end

  defp check_references(parsed, definitions) do
    with :ok <- check_cycle(parsed, definitions || []) do
      check_fields(Computed.references(parsed), definitions)
    end
  end

  defp check_cycle(parsed, definitions) do
    case cyclic_document_refs(parsed, definitions) do
      [] ->
        :ok

      refs ->
        {:error,
         gettext(
           "can't read %{refs}: the title is built from this template and the slug from the title",
           refs: Enum.join(refs, ", ")
         )}
    end
  end

  # `title`/`slug` read by the template itself or — transitively — by a computed
  # field it reads (`{{ field.label }}` over `{{ title }} (x)` is just as cyclic).
  defp cyclic_document_refs(parsed, definitions) do
    computed = for %{field_type: :computed, name: name, compute: c} <- definitions, do: {name, c}

    parsed
    |> Computed.references()
    |> reachable(Map.new(computed), MapSet.new())
    |> Enum.flat_map(&document_refs(Map.get(Map.new(computed), &1)))
    |> Kernel.++(document_refs(parsed))
    |> Enum.filter(&(&1 in @cyclic))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reachable([], _computed, seen), do: MapSet.to_list(seen)

  defp reachable([name | rest], computed, seen) do
    cond do
      MapSet.member?(seen, name) or not Map.has_key?(computed, name) ->
        reachable(rest, computed, seen)

      true ->
        reachable(Computed.references(computed[name]) ++ rest, computed, MapSet.put(seen, name))
    end
  end

  defp document_refs(nil), do: []

  defp document_refs(source) do
    case if(is_list(source), do: {:ok, source}, else: Computed.parse(source)) do
      {:ok, template} ->
        Enum.flat_map(template, fn
          {:expr, ast} -> ast_refs(ast)
          {:text, _text} -> []
        end)

      {:error, _message} ->
        []
    end
  end

  # A bare `title` is the document's; `field.title` is a custom field that
  # happens to share the name, which is fine.
  defp ast_refs({:ref, "field." <> _name}), do: []
  defp ast_refs({:ref, name}) when name in @cyclic, do: [name]
  defp ast_refs({:ref, _name}), do: []
  defp ast_refs({:call, _name, args}), do: Enum.flat_map(args, &ast_refs/1)
  defp ast_refs(_literal), do: []

  defp check_fields(_names, nil), do: :ok
  defp check_fields([], _definitions), do: :ok

  defp check_fields(names, definitions) do
    by_name = Map.new(definitions, &{&1.name, &1})

    case Enum.reject(names, &Map.has_key?(by_name, &1)) do
      [] -> check_private(names, by_name)
      unknown -> {:error, unknown_message(unknown, definitions)}
    end
  end

  defp check_private(names, by_name) do
    case Enum.filter(names, &(by_name[&1].private == true)) do
      [] ->
        :ok

      private ->
        {:error,
         gettext(
           "can't read the private field %{names}: a title is public",
           names: Enum.join(private, ", ")
         )}
    end
  end

  defp unknown_message(unknown, definitions) do
    defined = definitions |> Enum.map(& &1.name) |> Enum.sort()

    gettext("reads %{names}, which this type has no field for (fields: %{defined})",
      names: Enum.join(unknown, ", "),
      defined: if(defined == [], do: gettext("none yet"), else: Enum.join(defined, ", "))
    )
  end

  @doc """
  The build-time check for `use KilnCMS.CMS.Content, title_template: …`: the
  template, or a `CompileError`-worthy raise naming what is wrong. `nil` passes.
  """
  @spec validate!(String.t() | nil) :: String.t() | nil
  def validate!(nil), do: nil

  def validate!(template) when is_binary(template) do
    case validate(template, []) do
      :ok ->
        template

      {:error, message} ->
        raise ArgumentError, "invalid :title_template #{inspect(template)}: #{message}"
    end
  end

  def validate!(other),
    do: raise(ArgumentError, ":title_template must be a string, got: #{inspect(other)}")
end
