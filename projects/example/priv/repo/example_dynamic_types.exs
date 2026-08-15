# Creates the "Acme" example catalog's one **admin-defined (dynamic)**
# content type (D17): Event. Unlike Product/TeamMember/Testimonial/Faq, this
# needs no Elixir resource module or migration — it's the no-code path, the
# same one an admin would use from `/editor/types`, just scripted for a
# reproducible demo. Run with:
#
#     mix run projects/example/priv/repo/example_dynamic_types.exs
#
# Must run before `example_import.exs` (which creates Event entries) and
# after `example_field_definitions.exs` is not required, but running it
# first keeps a consistent seed order — see `projects/example/README.md`.
#
# Idempotent: looks up the type by `name` first, and each field definition by
# its (type_definition_id, name) identity, same convention as
# `example_field_definitions.exs`.

alias KilnCMS.Accounts
alias KilnCMS.CMS

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{role: :admin} = user} ->
      user

    _ ->
      raise "No admin user found for #{admin_email} — run priv/repo/seeds.exs first " <>
              "or set ADMIN_EMAIL."
  end

tenant = Accounts.default_org_id()
opts = [actor: admin, tenant: tenant]

type_definition =
  case CMS.get_type_definition_by_name("event", opts) do
    {:ok, type_definition} ->
      IO.puts("type: event (exists)")
      type_definition

    _not_found ->
      type_definition =
        CMS.create_type_definition!(
          %{
            name: "event",
            label: "Event",
            plural_label: "Events",
            has_excerpt: true,
            has_published_feed: true,
            # #357: the fired `:json_ld` main node — an Event `schedule`
            # field earns startDate/endDate/eventSchedule for free
            # (`KilnCMS.Firing.SchemaOrg`, `KilnCMS.Events.schema_org_schedule/1`).
            schema_org_type: "Event"
          },
          opts
        )

      IO.puts("type: event (created)")
      type_definition
  end

# `field_type: :datetime_range` is what makes an entry "event-shaped" at all
# (`KilnCMS.Events.event_type?/2` / `schedule_field/2`) — it alone earns a
# calendar entry and an ICS feed. Adding `:recurrence` additionally produces
# an RRULE. Both are core field types (`KilnCMS.CMS.FieldTypes.DatetimeRange`
# / `.Recurrence`), not plugin-contributed.
definitions = [
  %{
    name: "schedule",
    label: "Date & time",
    field_type: :datetime_range,
    required: true,
    help_text: "When the event starts and ends."
  },
  %{
    name: "recurrence",
    label: "Repeats",
    field_type: :recurrence,
    help_text: "Leave blank for a one-off event."
  },
  %{
    name: "location",
    label: "Location",
    field_type: :string,
    help_text: "Venue name or \"Online\"."
  }
]

existing =
  type_definition.id
  |> CMS.field_definitions_for_definition!(opts)
  |> Map.new(&{&1.name, &1})

definitions
|> Enum.with_index()
|> Enum.each(fn {attrs, position} ->
  attrs =
    attrs |> Map.put(:type_definition_id, type_definition.id) |> Map.put(:position, position)

  case Map.fetch(existing, attrs.name) do
    {:ok, definition} ->
      CMS.update_field_definition!(
        definition,
        Map.delete(attrs, :type_definition_id),
        opts
      )

      IO.puts("  updated event.#{attrs.name}")

    :error ->
      CMS.create_field_definition!(attrs, opts)
      IO.puts("  created event.#{attrs.name}")
  end
end)

IO.puts("Done: event type with #{length(definitions)} field definitions.")
