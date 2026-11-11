defmodule KilnCMSWeb.EditorLive.Filters do
  @moduledoc """
  The content list's filter state (#1593): read from the URL, written back to
  it, and turned into the query each content type's list runs.

  One map of string values, keyed like the query string, so the URL, a saved
  view's `params` and the form all speak the same shape:

  | Key         | Values                                                    |
  |-------------|-----------------------------------------------------------|
  | `status`    | `all` (default), `draft`, `in_review`, `published`, `archived` |
  | `type`      | `all` (default) or a content type the actor may author   |
  | `q`         | title/slug substring                                      |
  | `author`    | `me` or a user id                                         |
  | `category`  | a category id                                             |
  | `tag`       | a tag id                                                  |
  | `locale`    | one of the configured locales                             |
  | `from`/`to` | ISO dates, an inclusive range on the last update          |
  | `health`    | `due` (due or overdue for review), `due_soon`, `expired`  |
  | `reviewed`  | `never`: `mark_reviewed` has never run on the record      |
  | `consent_missing` | a consent kind the record has no consent of     |
  | `scheduled` | `1`: a publish date is set and it is not live yet         |
  | `sort`      | `updated` (default), `published`, `title`, or `field:<name>` / `-field:<name>` (a custom field, one type selected) |
  | `cf`        | custom-field conditions (one type selected), see below    |

  ## Custom-field conditions (`cf`) and field sort

  With ONE content type in play (the `type` filter names it, or the site has
  only one), the list can narrow by that type's custom fields and sort by one
  of them (#2293). `cf` is one string, so a saved view (flat strings) holds it
  like any other key: `field:op:value` segments joined by `;`, field and value
  URL-encoded (`URI.encode_www_form/1`, so neither holds a raw `:` or `;`),
  in canonical order (by field, then op) so equal filters give equal strings:

      price:gte:10;color:eq:red

  What is a valid field, op and value comes from `ctx.fields` (a function from
  a type value to that type's readable field definitions) and
  `KilnCMS.CMS.ListFieldQuery`. A condition that is not valid for the single
  type in play (unknown or private field, op not offered for its type, a value
  that does not cast) reads as absent, as does the whole of `cf` and a field
  sort when no single type is in play. At most four conditions; their encoded
  string at most `SavedView.max_cf_length/0` characters.

  Every value is checked against what it can be. Anything else reads as
  absent, so a hand-edited link or a saved view whose category was deleted
  narrows less instead of failing.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.CMS.ListFieldQuery
  alias KilnCMS.CMS.SavedView
  alias KilnCMSWeb.Params

  @statuses ~w(all draft in_review published archived)
  @healths ~w(due due_soon expired)
  @sorts ~w(updated published title)
  @reviewed ~w(never)

  @max_conditions 4
  # `cf` arrives from a URL: read no more segments than could ever be kept.
  @max_segments 12

  @defaults %{
    "status" => "all",
    "type" => "all",
    "q" => "",
    "author" => nil,
    "category" => nil,
    "tag" => nil,
    "locale" => nil,
    "from" => nil,
    "to" => nil,
    "health" => nil,
    "scheduled" => nil,
    "reviewed" => nil,
    "consent_missing" => nil,
    "cf" => nil,
    "sort" => "updated"
  }

  @typedoc "Filter state: every key in `SavedView.param_keys/0`, a string or `nil`."
  @type t :: %{required(String.t()) => String.t() | nil}

  @doc "The workflow states the status filter offers, `all` first."
  def statuses, do: @statuses

  @doc "The health values the health filter offers."
  def healths, do: @healths

  @doc "The values the review-history filter offers."
  def reviewed, do: @reviewed

  @doc """
  The consent kinds the missing-consent filter offers: the site's configured
  `KilnCMS.CMS.Consent.kinds/0`, as strings.
  """
  def consent_kinds, do: Enum.map(KilnCMS.CMS.Consent.kinds(), &Atom.to_string/1)

  @doc "The sort orders the list offers."
  def sorts, do: @sorts

  @doc "No filter at all."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  The filter `params` describe. `ctx` carries what a value is checked against:
  `:types` (the type values the actor may author) and `:locales`.
  """
  @spec parse(map(), map()) :: t()
  def parse(params, ctx) when is_map(params) do
    raw = Map.new(SavedView.param_keys(), &{&1, Params.string(params, &1)})
    type = one_of(raw["type"], ctx.types, "all")
    # Only a `cf` or a field sort needs the type's fields; a plain list asks
    # the lookup nothing.
    definitions = if needs_fields?(raw), do: field_definitions(type, ctx), else: []

    %{
      "status" => one_of(raw["status"], @statuses, "all"),
      "type" => type,
      "q" => String.trim(raw["q"] || ""),
      "author" => author(raw["author"]),
      "category" => uuid(raw["category"]),
      "tag" => uuid(raw["tag"]),
      "locale" => one_of(raw["locale"], ctx.locales, nil),
      "from" => date(raw["from"]),
      "to" => date(raw["to"]),
      "health" => one_of(raw["health"], @healths, nil),
      "scheduled" => if(raw["scheduled"] == "1", do: "1"),
      "reviewed" => one_of(raw["reviewed"], @reviewed, nil),
      "consent_missing" => one_of(raw["consent_missing"], consent_kinds(), nil),
      "cf" => raw["cf"] |> decode_conditions(definitions) |> encode_conditions(),
      "sort" => sort_param(raw["sort"], definitions)
    }
  end

  def parse(_params, ctx), do: parse(%{}, ctx)

  @doc """
  The query parameters for `filters`: only the keys that differ from the
  default, so the plain list is `/editor` and two equal filters give equal
  maps (which is how a saved view is recognised as the one on screen).
  """
  @spec to_params(t()) :: %{String.t() => String.t()}
  def to_params(filters) do
    for {key, value} <- filters,
        value not in [nil, ""],
        value != Map.get(@defaults, key),
        into: %{},
        do: {key, value}
  end

  @doc "Whether anything narrows or reorders the list."
  @spec active?(t()) :: boolean()
  def active?(filters), do: to_params(filters) != %{}

  @doc "Whether anything narrows the list, ignoring the sort order."
  @spec narrowing?(t()) :: boolean()
  def narrowing?(filters), do: filters |> to_params() |> Map.delete("sort") != %{}

  @doc """
  The Ash `:filter` entries for `filters`, the type aside (the list picks which
  types to read). `actor_id` is what `author=me` means.
  """
  @spec query_filters(t(), Ecto.UUID.t() | nil) :: keyword()
  def query_filters(filters, actor_id) do
    [
      status_filter(filters["status"]),
      search_filter(filters["q"]),
      author_filter(filters["author"], actor_id),
      filters["category"] && expr(category_id == ^filters["category"]),
      filters["tag"] && expr(exists(tags, id == ^filters["tag"])),
      filters["locale"] && expr(locale == ^filters["locale"]),
      from_filter(filters["from"]),
      to_filter(filters["to"]),
      health_filter(filters["health"]),
      filters["scheduled"] &&
        expr(not is_nil(scheduled_at) and state in [:draft, :in_review]),
      filters["reviewed"] == "never" && expr(is_nil(last_reviewed_at)),
      consent_missing_filter(filters["consent_missing"])
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.map(&{:filter, &1})
  end

  @doc """
  The Ash sort for `filters`. The primary key breaks ties, so keyset paging
  never skips or repeats a row.
  """
  @spec sort(t()) :: keyword()
  # A custom-field sort is not an Ash sort: it travels as a read argument
  # (`field_arguments/2`), the preparation orders by it, and Ash appends the
  # primary key itself when the read is keyset-paginated.
  def sort(%{"sort" => "field:" <> _}), do: []
  def sort(%{"sort" => "-field:" <> _}), do: []
  def sort(%{"sort" => "published"}), do: [published_at: :desc_nils_last, id: :desc]
  def sort(%{"sort" => "title"}), do: [title: :asc, id: :asc]
  def sort(_filters), do: [updated_at: :desc, id: :desc]

  @doc """
  Whether record `a` comes before record `b` in `filters`' order — the same
  order `sort/1` asks the database for, used to merge the per-type pages.
  """
  @spec before?(t(), map(), map()) :: boolean()
  # A field sort only exists with one type in play, so there is one stream and
  # nothing to merge. Merging two by `updated_at` instead would quietly show an
  # order the database did not ask for, so refuse.
  def before?(%{"sort" => "field:" <> _}, _a, _b), do: raise_single_stream()
  def before?(%{"sort" => "-field:" <> _}, _a, _b), do: raise_single_stream()

  def before?(%{"sort" => "published"}, a, b) do
    case {a.published_at, b.published_at} do
      {nil, nil} -> a.id >= b.id
      {nil, _} -> false
      {_, nil} -> true
      {x, y} -> desc(DateTime.compare(x, y), a, b)
    end
  end

  def before?(%{"sort" => "title"}, a, b) do
    x = String.downcase(a.title || "")
    y = String.downcase(b.title || "")
    if x == y, do: a.id <= b.id, else: x < y
  end

  def before?(_filters, a, b), do: desc(DateTime.compare(a.updated_at, b.updated_at), a, b)

  defp raise_single_stream,
    do:
      raise(
        ArgumentError,
        "a custom-field sort reads one content type; there is nothing to merge"
      )

  defp desc(:gt, _a, _b), do: true
  defp desc(:lt, _a, _b), do: false
  defp desc(:eq, a, b), do: a.id >= b.id

  # --- custom-field conditions and sort (#2293) -------------------------------

  @doc "The most custom-field conditions the list holds."
  @spec max_conditions() :: pos_integer()
  def max_conditions, do: @max_conditions

  @doc """
  The conditions `filters` holds, as `ListFieldQuery.condition/0` maps in
  canonical order. `filters` came from `parse/2`, so every one is valid.
  """
  @spec conditions(t()) :: [ListFieldQuery.condition()]
  def conditions(%{"cf" => cf}) when is_binary(cf), do: decode_segments(cf)
  def conditions(_filters), do: []

  @doc "The custom-field sort `filters` asks for, as `{name, :asc | :desc}`, or `nil`."
  @spec field_sort(t()) :: ListFieldQuery.sort()
  def field_sort(%{"sort" => "field:" <> name}), do: {name, :asc}
  def field_sort(%{"sort" => "-field:" <> name}), do: {name, :desc}
  def field_sort(_filters), do: nil

  @doc "The `sort` filter value for a field sort."
  @spec field_sort_value(String.t(), :asc | :desc) :: String.t()
  def field_sort_value(name, :asc), do: "field:" <> name
  def field_sort_value(name, :desc), do: "-field:" <> name

  @doc "Whether `filters` carries a custom-field condition or sort (a field-filtered read)."
  @spec field_query?(t()) :: boolean()
  def field_query?(filters), do: conditions(filters) != [] or field_sort(filters) != nil

  @doc """
  The read arguments for `filters`' conditions and sort, `%{}` when it has
  none. `definitions` are the field definitions of the type in play.
  """
  @spec field_arguments(t(), [map()]) :: map()
  def field_arguments(filters, definitions),
    do: ListFieldQuery.arguments(conditions(filters), field_sort(filters), definitions)

  @doc "`filters` without custom-field conditions or a field sort."
  @spec clear_field_query(t()) :: t()
  def clear_field_query(filters) do
    filters = Map.put(filters, "cf", nil)
    if field_sort(filters), do: Map.put(filters, "sort", "updated"), else: filters
  end

  @doc """
  `filters` with `changes` applied (not yet parsed). Changing the content
  type clears the conditions and the field sort: they were chosen from the
  old type's fields, and a field of the same name on the new type is a
  different field.
  """
  @spec merge(t(), map()) :: map()
  def merge(filters, changes) do
    merged = Map.merge(filters, changes)

    if Map.has_key?(changes, "type") and changes["type"] != filters["type"],
      do: clear_field_query(merged),
      else: merged
  end

  @doc """
  `filters` with the condition `field` `op` `value` added (it replaces a
  condition on the same field and op), checked against `definitions` as
  `parse/2` would.

  `{:error, :invalid}` when it is not a condition the type offers;
  `{:error, :limit}` when it would exceed #{@max_conditions} conditions or the
  stored length of `cf` — never a silent drop.
  """
  @spec add_condition(t(), [map()], term(), term(), term()) ::
          {:ok, t()} | {:error, :invalid | :limit}
  def add_condition(filters, definitions, field, op, value)
      when is_binary(field) and is_binary(op) and is_binary(value) do
    with %{} = definition <- Enum.find(definitions, &(&1.name == field)),
         {:ok, canonical} <- ListFieldQuery.cast(definition, op, value) do
      kept = Enum.reject(conditions(filters), &(&1.field == field and &1.op == op))
      added = canonicalize([%{field: field, op: op, value: canonical} | kept])

      if length(added) <= @max_conditions and encoded_fits?(added),
        do: {:ok, Map.put(filters, "cf", encode_conditions(added))},
        else: {:error, :limit}
    else
      _ -> {:error, :invalid}
    end
  end

  def add_condition(_filters, _definitions, _field, _op, _value), do: {:error, :invalid}

  @doc "`filters` without the condition on `field` with `op`."
  @spec remove_condition(t(), String.t(), String.t()) :: t()
  def remove_condition(filters, field, op) do
    kept = Enum.reject(conditions(filters), &(&1.field == field and &1.op == op))
    Map.put(filters, "cf", encode_conditions(kept))
  end

  @doc """
  How many conditions `params`' `cf` named that `parse/2` did not keep (a
  field since deleted or made private, a retyped field's old value). A saved
  view that returns more than zero is stale.
  """
  @spec dropped_conditions(map(), map()) :: non_neg_integer()
  def dropped_conditions(params, ctx) when is_map(params) do
    case Params.string(params, "cf") do
      nil ->
        0

      cf ->
        definitions = params |> field_type_in_play(ctx) |> field_definitions(ctx)
        by_name = Map.new(definitions, &{&1.name, &1})

        # Distinct, well-formed conditions only: a repeated one, a malformed
        # segment, or one past the cap lost nothing the view meant.
        cf
        |> decode_segments()
        |> Enum.uniq_by(&{&1.field, &1.op})
        |> Enum.count(&(valid_condition(by_name, &1) == :error))
    end
  end

  def dropped_conditions(_params, _ctx), do: 0

  @doc """
  Whether the view or URL `params` names something that no longer applies: a
  condition `dropped_conditions/2` counts, or a field sort that `parse/2`
  turned back into the default order.
  """
  @spec stale?(map(), map()) :: boolean()
  def stale?(params, ctx) when is_map(params) do
    dropped_conditions(params, ctx) > 0 or
      (field_sort_param?(Params.string(params, "sort")) and
         field_sort(parse(params, ctx)) == nil)
  end

  def stale?(_params, _ctx), do: false

  @doc """
  Whether `params` ask for something only a type's field definitions can
  validate: a `cf`, or a `field:`/`-field:` sort.
  """
  @spec needs_fields?(map()) :: boolean()
  def needs_fields?(params) when is_map(params),
    do: Params.string(params, "cf") != nil or field_sort_param?(Params.string(params, "sort"))

  def needs_fields?(_params), do: false

  defp field_sort_param?("field:" <> _), do: true
  defp field_sort_param?("-field:" <> _), do: true
  defp field_sort_param?(_sort), do: false

  @doc """
  The one content type whose fields `params` can filter and sort by: the type
  it names, or a site's only type (the rule the column strip uses); `nil` when
  several types are in play.
  """
  @spec field_type_in_play(map(), map()) :: String.t() | nil
  def field_type_in_play(params, ctx) when is_map(params),
    do: params |> Params.string("type") |> one_of(ctx.types, "all") |> single_type(ctx)

  defp single_type("all", %{types: [only]}), do: only
  defp single_type("all", _ctx), do: nil
  defp single_type(type, _ctx), do: type

  # The readable definitions of that type, from the caller's lookup.
  defp field_definitions(type, ctx) do
    with single when is_binary(single) <- single_type(type, ctx),
         lookup when is_function(lookup, 1) <- Map.get(ctx, :fields) do
      lookup.(single)
    else
      _ -> []
    end
  end

  defp sort_param(raw, definitions) do
    cond do
      raw in @sorts -> raw
      field_sort_allowed?(raw, definitions) -> raw
      true -> "updated"
    end
  end

  defp field_sort_allowed?(raw, definitions) when is_binary(raw) do
    name =
      case raw do
        "field:" <> name -> name
        "-field:" <> name -> name
        _ -> nil
      end

    name != nil and Enum.any?(definitions, &(&1.name == name and ListFieldQuery.sortable?(&1)))
  end

  defp field_sort_allowed?(_raw, _definitions), do: false

  defp decode_conditions(nil, _definitions), do: []
  defp decode_conditions(_cf, []), do: []

  defp decode_conditions(cf, definitions) do
    by_name = Map.new(definitions, &{&1.name, &1})

    cf
    |> decode_segments()
    |> Enum.flat_map(fn condition ->
      case valid_condition(by_name, condition) do
        {:ok, valid} -> [valid]
        :error -> []
      end
    end)
    |> canonicalize()
    |> Enum.take(@max_conditions)
    |> fit_length()
  end

  defp valid_condition(by_name, %{field: field, op: op, value: value} = condition) do
    with %{} = definition <- Map.get(by_name, field),
         {:ok, canonical} <- ListFieldQuery.cast(definition, op, value) do
      {:ok, %{condition | value: canonical}}
    else
      _ -> :error
    end
  end

  # `field:op:value` segments; an undecodable or malformed one is skipped.
  defp decode_segments(cf) do
    cf
    |> String.split(";", trim: true)
    |> Enum.take(@max_segments)
    |> Enum.flat_map(fn segment ->
      with [field, op, value] <- String.split(segment, ":", parts: 3),
           {:ok, field} <- decode_part(field),
           {:ok, value} <- decode_part(value) do
        [%{field: field, op: op, value: value}]
      else
        _ -> []
      end
    end)
  end

  # `URI.decode_www_form/1` raises on a bad percent escape, and the text comes
  # straight from a URL or a saved view: an error is "not a condition".
  defp decode_part(part) do
    decoded = URI.decode_www_form(part)
    if String.valid?(decoded), do: {:ok, decoded}, else: :error
  rescue
    ArgumentError -> :error
  end

  # Canonical order and one condition per field and op, so equal filters give
  # the same string.
  defp canonicalize(conditions) do
    conditions
    |> Enum.uniq_by(&{&1.field, &1.op})
    |> Enum.sort_by(&{&1.field, &1.op})
  end

  defp encode_conditions([]), do: nil

  defp encode_conditions(conditions) do
    Enum.map_join(conditions, ";", fn %{field: field, op: op, value: value} ->
      URI.encode_www_form(field) <> ":" <> op <> ":" <> URI.encode_www_form(value)
    end)
  end

  defp encoded_fits?(conditions),
    do: String.length(encode_conditions(conditions) || "") <= SavedView.max_cf_length()

  # Drop from the end until the encoded string fits what a saved view stores.
  defp fit_length([]), do: []

  defp fit_length(conditions),
    do: if(encoded_fits?(conditions), do: conditions, else: fit_length(Enum.drop(conditions, -1)))

  @doc """
  The built-in views every editor starts with. Not stored: they are filters
  with a name, so there is nothing to rename or delete.
  """
  @spec default_views() :: [%{id: String.t(), name: String.t(), params: map()}]
  def default_views do
    [
      %{id: "all", name: gettext("All content"), params: %{}},
      %{
        id: "my-drafts",
        name: gettext("My drafts"),
        params: %{"status" => "draft", "author" => "me"}
      },
      %{id: "needs-review", name: gettext("Needs review"), params: %{"status" => "in_review"}},
      %{id: "scheduled", name: gettext("Scheduled"), params: %{"scheduled" => "1"}},
      %{id: "review-due", name: gettext("Review due"), params: %{"health" => "due"}}
    ]
  end

  @doc "Human label for a status filter value."
  def status_label("draft"), do: gettext("Draft")
  def status_label("in_review"), do: gettext("In review")
  def status_label("published"), do: gettext("Published")
  def status_label("archived"), do: gettext("Archived")

  @doc "Human label for a health filter value."
  def health_label("due"), do: gettext("Review due")
  def health_label("due_soon"), do: gettext("Review due soon")
  def health_label("expired"), do: gettext("Expired")

  @doc "Human label for a review-history filter value."
  def reviewed_label("never"), do: gettext("Never reviewed")

  @doc "Human label for a consent kind, e.g. `medical_review` → \"Medical review\"."
  def consent_kind_label(kind), do: kind |> String.replace("_", " ") |> String.capitalize()

  @doc "Human label for a sort order."
  def sort_label("updated"), do: gettext("Last updated")
  def sort_label("published"), do: gettext("Last published")
  def sort_label("title"), do: gettext("Title (A–Z)")

  defp one_of(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp author("me"), do: "me"
  defp author(value), do: uuid(value)

  defp uuid(nil), do: nil

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp date(nil), do: nil

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _} -> nil
    end
  end

  defp status_filter("all"), do: nil
  defp status_filter(status), do: expr(state == ^String.to_existing_atom(status))

  defp search_filter(""), do: nil

  # Case-insensitive title/slug match; %, _ and \ in the input match literally.
  defp search_filter(q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
    expr(ilike(title, ^pattern) or ilike(slug, ^pattern))
  end

  defp author_filter(nil, _actor_id), do: nil
  defp author_filter("me", nil), do: expr(is_nil(author_id) and not is_nil(author_id))
  defp author_filter("me", actor_id), do: expr(author_id == ^actor_id)
  defp author_filter(id, _actor_id), do: expr(author_id == ^id)

  defp from_filter(nil), do: nil

  defp from_filter(iso) do
    from = iso |> Date.from_iso8601!() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    expr(updated_at >= ^from)
  end

  defp to_filter(nil), do: nil

  # Inclusive of the whole `to` day: everything before the next midnight.
  defp to_filter(iso) do
    until = iso |> Date.from_iso8601!() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    expr(updated_at < ^until)
  end

  # No consent of `kind` names this record. Consents point at content by id
  # (a soft reference, no relationship), hence the unrelated `exists`; ids are
  # UUIDs, so `content_id` alone identifies the record whatever its type. The
  # consent read is authorized as the list's actor, which every editor passes
  # (`KilnCMS.CMS.Consent` policies), and tenant-scoped like the list.
  defp consent_missing_filter(nil), do: nil

  defp consent_missing_filter(kind) do
    kind = String.to_existing_atom(kind)
    expr(not exists(KilnCMS.CMS.Consent, kind == ^kind and content_id == parent(id)))
  end

  defp health_filter(nil), do: nil
  defp health_filter("due"), do: expr(health in [:due, :overdue])
  defp health_filter("due_soon"), do: expr(health == :due_soon)
  defp health_filter("expired"), do: expr(health == :expired)
end
