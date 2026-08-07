defmodule KilnCMS.Events do
  @moduledoc """
  Event support: the small shared surface behind the `datetime_range` and
  `recurrence` field types, the ICS output and the `Event` JSON-LD node (#480).

  Kiln has no `Event` *resource*. An event is a dynamic content type (D17) that
  happens to carry a `datetime_range` field — which is what makes "event" a
  thing an operator composes at `/editor/types` rather than a thing Kiln
  hardcodes and a site has to bend to fit.

  That composition is also the discriminator: `schedule_field/1` looks for a
  `datetime_range` field definition, and a type that has one is event-shaped.
  Deliberately *not* `schema_org_type == "Event"` — that field is about
  structured-data output, and a type could reasonably be an `Event` for search
  engines without carrying a machine-readable schedule.

  ## Timezones

  The deployment default (`config :kiln_cms, KilnCMS.Events, time_zone:`) is the
  fallback for a value that names none. It defaults to `"Etc/UTC"`, which is
  honest rather than helpful: an operator running a venue should set it, and an
  editor can override it per event.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition

  @default_time_zone "Etc/UTC"
  @registry_ttl :timer.minutes(10)

  @doc """
  The deployment's default timezone for events with no explicit one.

      config :kiln_cms, KilnCMS.Events, time_zone: "Europe/London"
  """
  @spec default_time_zone() :: String.t()
  def default_time_zone do
    case Application.get_env(:kiln_cms, __MODULE__, [])[:time_zone] do
      zone when is_binary(zone) -> if known_time_zone?(zone), do: zone, else: @default_time_zone
      _other -> @default_time_zone
    end
  end

  @doc """
  Whether `zone` is a zone the configured database knows.

  Asked of editor input, so it must not raise on junk — and asked *before*
  storing, so a value that would blow up at render time is refused at the form.
  """
  @spec known_time_zone?(term()) :: boolean()
  def known_time_zone?(zone) when is_binary(zone) do
    match?({:ok, _}, DateTime.from_naive(~N[2026-01-01 12:00:00], zone))
  end

  def known_time_zone?(_zone), do: false

  @doc """
  A local wall time in `zone`, as a UTC instant.

  DST gaps and ambiguities resolve exactly as `KilnCMS.Events.Recurrence`
  resolves them — forward past a gap, first of an ambiguous pair — because a
  range and its recurrences must not disagree about what "01:30" meant. That is
  a delegation, not a promise: two identical copies stay identical only by
  luck.
  """
  @spec to_utc(NaiveDateTime.t(), String.t()) :: {:ok, DateTime.t()} | :error
  defdelegate to_utc(naive, zone), to: KilnCMS.Events.Recurrence

  @typedoc """
  How to find a type's field definitions.

  A compiled type is named by an atom; a dynamic one is named by its
  `TypeDefinition` id — the two hang off *different columns*
  (`FieldDefinition` has `content_type` XOR `type_definition_id`), so the scope
  has to say which. A record resolves to the right one through `scope_for/1`.
  """
  @type scope :: {:content_type, atom() | String.t()} | {:definition, Ash.UUID.t()}

  @doc """
  The scope a record's field definitions live under.

  A dynamic entry's definitions hang off its `type_definition_id`, **not** the
  `:entry` storage tier every dynamic type shares — looking up by resource would
  find one type's fields for another type's document, and looking up by *name*
  finds nothing at all, because the name is not a column on `FieldDefinition`.

  A record read with a `select:` that omitted `type_definition_id` carries an
  `%Ash.NotLoaded{}` there, and `not is_nil/1` is perfectly happy with one — so
  the unloaded case is matched *before* the id case. Without that guard the
  struct travels as a scope and raises deep inside a query builder, a long way
  from the `select:` that caused it.
  """
  @spec scope_for(struct()) :: scope() | nil
  def scope_for(%{type_definition_id: %Ash.NotLoaded{}}), do: nil
  def scope_for(%{type_definition_id: id}) when not is_nil(id), do: {:definition, id}

  def scope_for(%resource{}) do
    case KilnCMS.CMS.ContentTypes.type_name(resource) do
      nil -> nil
      name -> {:content_type, name}
    end
  end

  def scope_for(_record), do: nil

  @doc """
  The scope a *content-type descriptor's* field definitions live under.

  The descriptor half of `scope_for/1`, and it must agree with it *exactly* —
  callers key a map by one and look it up with the other. A compiled
  descriptor's `:type` is the raw atom `:post` while `ContentTypes.type_name/1`
  stringifies, so the name is normalised here: `{:content_type, :post}` and
  `{:content_type, "post"}` are different map keys, and the mismatch was
  invisible everywhere else because `definitions/2` accepts both spellings.
  """
  @spec scope_for_descriptor(map()) :: scope() | nil
  def scope_for_descriptor(%{source: :dynamic, definition: %{id: id}}), do: {:definition, id}

  def scope_for_descriptor(%{type: type}) when not is_nil(type),
    do: {:content_type, to_string(type)}

  def scope_for_descriptor(_descriptor), do: nil

  @doc """
  Every content type in `org_id` that carries a schedule, and so has a calendar.

  Not filtered by `published_feed?`: that flag is about *syndication*, and an
  operator who turns a type's Atom feed off has said nothing about whether its
  events belong in a calendar. Publication is still enforced at read time — this
  only decides which types have an `.ics` route at all.
  """
  @spec calendar_types(Ash.UUID.t()) :: [map()]
  def calendar_types(org_id) do
    # Cached, because this is one field-definition read *per content type* and
    # it runs on the public `.ics` routes before the response cache is even
    # consulted — so an org with twenty types paid twenty queries on every
    # request, cache hits and 404s included. Busted by `BustTypeRegistry`, which
    # now runs on `FieldDefinition` writes too, since a field is what decides
    # the answer.
    KilnCMS.Cache.fetch(KilnCMS.Cache.calendar_types_key(org_id), @registry_ttl, fn ->
      ContentTypes.all_for_org(org_id)
      |> Enum.filter(&event_type?(scope_for_descriptor(&1), org_id))
    end)
  end

  @doc """
  The `datetime_range` field definition in `scope`, or `nil`.

  A type with one is event-shaped: it can be put in a calendar, exported as ICS,
  and described as a schema.org `Event`. The *first* such field is the schedule
  when a type has several — one calendar entry per document, not per field.
  """
  @spec schedule_field(scope() | nil, Ash.UUID.t()) :: FieldDefinition.t() | nil
  def schedule_field(scope, org_id), do: find_field(scope, org_id, :datetime_range)

  @doc "The `recurrence` field definition in `scope`, or `nil`."
  @spec recurrence_field(scope() | nil, Ash.UUID.t()) :: FieldDefinition.t() | nil
  def recurrence_field(scope, org_id), do: find_field(scope, org_id, :recurrence)

  @doc "Whether this scope carries a schedule, and so is event-shaped."
  @spec event_type?(scope() | nil, Ash.UUID.t()) :: boolean()
  def event_type?(scope, org_id), do: not is_nil(schedule_field(scope, org_id))

  # `field_type` is an **atom** attribute, not a string. Comparing it against a
  # string matches nothing and silently makes every type non-event-shaped, with
  # no error anywhere — which is exactly what it did until the end-to-end test
  # caught it.
  defp find_field(scope, org_id, field_type) do
    scope
    |> definitions(org_id)
    |> Enum.find(&(&1.field_type == field_type))
  end

  @doc """
  The schema.org date properties for an Event-typed document.

  `%{}` when the document carries no schedule — a type declared `Event` with no
  `datetime_range` field is allowed, and simply produces an Event with no dates
  rather than an error. The type is what an operator says it is.

  A recurrence rides as `eventSchedule`, schema.org's own `Schedule`, which
  carries an RRULE verbatim. That is deliberately not a window of expanded
  instances: expansion is correct only at the moment it is fired, and a fired
  artifact outlives that moment.
  """
  @spec schema_org_schedule(struct()) :: map()
  def schema_org_schedule(record) do
    org_id = Map.get(record, :org_id)

    case schedule_value(record, org_id) do
      nil ->
        %{}

      value ->
        case KilnCMS.CMS.FieldTypes.DatetimeRange.to_utc(value) do
          nil -> %{}
          {start_utc, end_utc} -> dates(start_utc, end_utc, record, org_id)
        end
    end
  end

  defp dates(start_utc, end_utc, record, org_id) do
    %{"startDate" => DateTime.to_iso8601(start_utc)}
    |> put_present("endDate", end_utc && DateTime.to_iso8601(end_utc))
    |> put_present("eventSchedule", event_schedule(record, org_id))
  end

  defp event_schedule(record, org_id) do
    case recurrence_rule(record, org_id) do
      nil ->
        nil

      rule ->
        %{
          "@type" => "Schedule",
          "repeatFrequency" => "RRULE:" <> KilnCMS.Events.Recurrence.to_rrule(rule)
        }
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The stored `datetime_range` value on `record`, or `nil`.

  Shared rather than re-derived: ICS, occurrence expansion and the JSON-LD node
  all need "the schedule on this document", and three copies of
  definition-lookup-then-custom_fields-fetch is three places for the
  dynamic-type lookup below to be got wrong.
  """
  @spec schedule_value(struct(), Ash.UUID.t() | nil) :: map() | nil
  def schedule_value(record, org_id), do: field_value(record, org_id, &schedule_field/2)

  @doc "The parsed recurrence rule on `record`, or `nil`."
  @spec recurrence_rule(struct(), Ash.UUID.t() | nil) :: KilnCMS.Events.Recurrence.t() | nil
  def recurrence_rule(record, org_id) do
    case field_value(record, org_id, &recurrence_field/2) do
      nil -> nil
      value -> KilnCMS.CMS.FieldTypes.Recurrence.rule_with_exdates(value)
    end
  end

  defp field_value(record, org_id, finder) do
    org_id = org_id || Map.get(record, :org_id)

    with scope when not is_nil(scope) <- scope_for(record),
         %{} = definition <- finder.(scope, org_id),
         %{} = value <- record |> Map.get(:custom_fields, %{}) |> Map.get(definition.name) do
      value
    else
      _other -> nil
    end
  end

  # No blanket rescue. An earlier draft had one, and it turned "the lookup is
  # querying the wrong column" into "this type has no fields" — every event in
  # the suite silently became a non-event, with nothing to read. A read that
  # fails here is a fault worth surfacing.
  defp definitions(nil, _org_id), do: []

  defp definitions({:definition, id}, org_id) do
    KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false, tenant: org_id)
  end

  defp definitions({:content_type, type}, org_id) when is_atom(type) do
    KilnCMS.CMS.field_definitions_for!(type, authorize?: false, tenant: org_id)
  end

  defp definitions({:content_type, type}, org_id) when is_binary(type) do
    case safe_atom(type) do
      nil -> []
      atom -> definitions({:content_type, atom}, org_id)
    end
  end

  defp safe_atom(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> nil
  end
end
