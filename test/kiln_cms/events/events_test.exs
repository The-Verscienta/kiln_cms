defmodule KilnCMS.EventsTest do
  @moduledoc """
  Event support composed the way an operator composes it (#480): a dynamic
  content type carrying a `datetime_range`, optionally a `recurrence`.

  Nothing here creates an "Event resource", because there isn't one — that is
  the design, and this file is what proves it works end to end without one.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Events
  alias KilnCMS.Events.ICS
  alias KilnCMS.Events.Occurrences

  @london "Europe/London"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "events-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "evt#{System.unique_integer([:positive])}"

    td =
      CMS.create_type_definition!(%{name: name, label: "Event", path_segment: name}, actor: admin)

    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
      actor: admin
    )

    %{admin: admin, td: td, type: name, org: KilnCMS.Accounts.default_org_id()}
  end

  defp add_recurrence(td, admin) do
    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "repeats", label: "Repeats", field_type: "recurrence"},
      actor: admin
    )
  end

  defp event!(ctx, custom_fields, attrs \\ %{}) do
    CMS.create_entry!(
      Map.merge(
        %{
          title: "A gig",
          slug: "ev-#{System.unique_integer([:positive])}",
          type_definition_id: ctx.td.id,
          custom_fields: custom_fields
        },
        attrs
      ),
      actor: ctx.admin
    )
  end

  defp utc(iso), do: iso |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

  describe "a type carrying a datetime_range is event-shaped" do
    test "and one without it is not", ctx do
      assert Events.event_type?({:definition, ctx.td.id}, ctx.org)

      other =
        CMS.create_type_definition!(%{name: "n#{System.unique_integer([:positive])}", label: "N"},
          actor: ctx.admin
        )

      refute Events.event_type?({:definition, other.id}, ctx.org)
    end

    test "the schedule is stored as local time plus a zone, not a UTC instant", ctx do
      event =
        event!(ctx, %{
          "when" => %{
            "start" => "2026-03-15T19:00",
            "end" => "2026-03-15T21:00",
            "time_zone" => @london
          }
        })

      # An event is a fact about the local clock; the instant is derived. Storing
      # UTC would silently move the gig if the zone's rules ever changed.
      assert %{"start" => "2026-03-15T19:00:00", "time_zone" => @london} =
               event.custom_fields["when"]
    end

    test "an unknown timezone is refused at the form, not at render", ctx do
      assert {:error, error} =
               CMS.create_entry(
                 %{
                   title: "Bad",
                   slug: "ev-#{System.unique_integer([:positive])}",
                   type_definition_id: ctx.td.id,
                   custom_fields: %{
                     "when" => %{"start" => "2026-03-15T19:00", "time_zone" => "Mars/Olympus"}
                   }
                 },
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "timezone"
    end

    test "an end before the start is refused", ctx do
      assert {:error, error} =
               CMS.create_entry(
                 %{
                   title: "Backwards",
                   slug: "ev-#{System.unique_integer([:positive])}",
                   type_definition_id: ctx.td.id,
                   custom_fields: %{
                     "when" => %{"start" => "2026-03-15T21:00", "end" => "2026-03-15T19:00"}
                   }
                 },
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "before the start"
    end
  end

  describe "the all-day flag round-trips through the editor" do
    alias KilnCMS.CMS.FieldTypes.DatetimeRange

    test ~s(the checkbox part submits "true"/"false", and both are understood) do
      # The composite renderer pairs a checkbox with a hidden `false`, so an
      # unticked box submits the string "false" rather than nothing at all.
      assert {:ok, %{"all_day" => true}} =
               DatetimeRange.cast(%{"start" => "2026-03-15T00:00", "all_day" => "true"}, nil)

      assert {:ok, %{"all_day" => false}} =
               DatetimeRange.cast(%{"start" => "2026-03-15T00:00", "all_day" => "false"}, nil)

      # And a value coming back out of jsonb is a real boolean, not a string.
      assert {:ok, %{"all_day" => true}} =
               DatetimeRange.cast(%{"start" => "2026-03-15T00:00", "all_day" => true}, nil)
    end

    test "a stored all-day event survives a save that does not touch it", ctx do
      event =
        event!(ctx, %{
          "when" => %{"start" => "2026-03-15T00:00", "time_zone" => @london, "all_day" => "true"}
        })

      assert event.custom_fields["when"]["all_day"] == true

      updated =
        CMS.update_entry!(event, %{title: "Renamed"}, actor: ctx.admin)

      assert updated.custom_fields["when"]["all_day"] == true
    end
  end

  describe "occurrences" do
    test "a one-off event is a series of one, window-filtered", ctx do
      event = event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00", "time_zone" => @london}})

      assert [occurrence] =
               Occurrences.for_record(
                 event,
                 utc("2026-03-01T00:00:00"),
                 utc("2026-03-31T00:00:00")
               )

      assert DateTime.to_date(occurrence.starts_at) == ~D[2026-03-15]

      # Outside the window it simply is not on.
      assert [] =
               Occurrences.for_record(
                 event,
                 utc("2026-04-01T00:00:00"),
                 utc("2026-04-30T00:00:00")
               )
    end

    test "a recurring event expands, and the duration recurs rather than the end", ctx do
      add_recurrence(ctx.td, ctx.admin)

      event =
        event!(ctx, %{
          "when" => %{
            "start" => "2026-03-15T19:00",
            "end" => "2026-03-15T21:00",
            "time_zone" => @london
          },
          "repeats" => %{"rrule" => "FREQ=WEEKLY;BYDAY=SU"}
        })

      occurrences =
        Occurrences.for_record(event, utc("2026-03-01T00:00:00"), utc("2026-04-13T00:00:00"))

      assert length(occurrences) == 5

      # Two hours on every occurrence — including across the 29 March DST change,
      # where the UTC offsets on the two sides differ.
      for occurrence <- occurrences do
        assert DateTime.diff(occurrence.ends_at, occurrence.starts_at, :second) == 7200
      end

      local_times =
        Enum.map(occurrences, fn o ->
          o.starts_at |> DateTime.shift_zone!(@london) |> DateTime.to_time()
        end)

      assert Enum.uniq(local_times) == [~T[19:00:00]]
    end

    test "skipped dates are honoured", ctx do
      add_recurrence(ctx.td, ctx.admin)

      event =
        event!(ctx, %{
          "when" => %{"start" => "2026-03-01T19:00", "time_zone" => @london},
          "repeats" => %{"rrule" => "FREQ=DAILY", "exdates" => ["2026-03-03"]}
        })

      dates =
        event
        |> Occurrences.for_record(utc("2026-03-01T00:00:00"), utc("2026-03-05T00:00:00"))
        |> Enum.map(&DateTime.to_date(&1.starts_at))

      refute ~D[2026-03-03] in dates
    end

    test "a document on a type with no schedule field yields nothing", ctx do
      other =
        CMS.create_type_definition!(%{name: "n#{System.unique_integer([:positive])}", label: "N"},
          actor: ctx.admin
        )

      entry =
        CMS.create_entry!(
          %{
            title: "Not an event",
            slug: "ne-#{System.unique_integer([:positive])}",
            type_definition_id: other.id
          },
          actor: ctx.admin
        )

      # A caller never has to ask "is this an event?" first.
      assert Occurrences.for_record(entry, utc("2026-01-01T00:00:00"), utc("2027-01-01T00:00:00")) ==
               []
    end

    test "next/3 answers nil beyond the horizon rather than searching forever", ctx do
      event = event!(ctx, %{"when" => %{"start" => "2030-03-15T19:00", "time_zone" => @london}})

      refute Occurrences.next(event, utc("2026-01-01T00:00:00"), horizon_days: 30)
      assert Occurrences.next(event, utc("2026-01-01T00:00:00"), horizon_days: 2000)
    end
  end

  describe "ICS" do
    test "a one-off event renders a VEVENT with a local time and a TZID", ctx do
      event =
        event!(
          ctx,
          %{
            "when" => %{
              "start" => "2026-03-15T19:00",
              "end" => "2026-03-15T21:00",
              "time_zone" => @london
            }
          },
          %{title: "The gig"}
        )

      ics = ICS.event(event, org_id: ctx.org)

      assert ics =~ "BEGIN:VCALENDAR"
      assert ics =~ "BEGIN:VEVENT"
      assert ics =~ "DTSTART;TZID=Europe/London:20260315T190000"
      assert ics =~ "DTEND;TZID=Europe/London:20260315T210000"
      assert ics =~ "SUMMARY:The gig"
      assert ics =~ "UID:#{event.id}@kiln"
      # CRLF line endings are required by RFC 5545, not cosmetic.
      assert ics =~ "\r\n"
    end

    test "a recurring event ships the RULE, not expanded occurrences", ctx do
      add_recurrence(ctx.td, ctx.admin)

      event =
        event!(ctx, %{
          "when" => %{"start" => "2026-03-15T19:00", "time_zone" => @london},
          "repeats" => %{"rrule" => "FREQ=WEEKLY;BYDAY=SU", "exdates" => ["2026-04-05"]}
        })

      ics = ICS.event(event, org_id: ctx.org)

      # A client understands RRULE and keeps showing occurrences past whatever
      # window Kiln happened to expand — smaller *and* more correct.
      assert ics =~ "RRULE:FREQ=WEEKLY;BYDAY=SU"
      assert ics =~ "EXDATE"
      assert ics |> String.split("BEGIN:VEVENT") |> length() == 2
    end

    test "an all-day event uses VALUE=DATE with an exclusive end", ctx do
      event =
        event!(ctx, %{
          "when" => %{
            "start" => "2026-03-15T00:00",
            "end" => "2026-03-15T00:00",
            "time_zone" => @london,
            "all_day" => true
          }
        })

      ics = ICS.event(event, org_id: ctx.org)

      assert ics =~ "DTSTART;VALUE=DATE:20260315"
      # RFC 5545's all-day DTEND is exclusive — omitting the +1 renders every
      # all-day event a day short, the classic ICS bug.
      assert ics =~ "DTEND;VALUE=DATE:20260316"
    end

    test "escapes commas, semicolons and newlines per RFC 5545, not per HTML", ctx do
      event =
        event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00"}}, %{
          title: "Jazz, blues; and\nsoul"
        })

      ics = ICS.event(event, org_id: ctx.org)

      assert ics =~ "SUMMARY:Jazz\\, blues\\; and\\nsoul"
    end

    test "strips control characters, which the format cannot represent", ctx do
      event =
        event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00"}}, %{
          title: "Bad" <> <<0x07>> <> "title"
        })

      ics = ICS.event(event, org_id: ctx.org)

      assert ics =~ "SUMMARY:Badtitle"
      refute ics =~ <<0x07>>
    end

    test "folds long lines at 75 octets, never mid-codepoint", ctx do
      # A multi-byte title is what catches character-based folding: splitting on
      # characters produces a file some parsers reject and others render as
      # mojibake.
      title = String.duplicate("é", 90)
      event = event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00"}}, %{title: title})

      ics = ICS.event(event, org_id: ctx.org)

      for line <- String.split(ics, "\r\n") do
        assert byte_size(line) <= 76, "line over 75 octets: #{inspect(line)}"
      end

      # Unfolding puts it back together — proof nothing was cut mid-codepoint.
      unfolded = String.replace(ics, "\r\n ", "")
      assert unfolded =~ "SUMMARY:" <> title
    end

    test "a calendar of several events, skipping documents with no schedule", ctx do
      a = event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00"}}, %{title: "One"})
      b = event!(ctx, %{"when" => %{"start" => "2026-03-16T19:00"}}, %{title: "Two"})
      c = event!(ctx, %{}, %{title: "No schedule"})

      ics = ICS.calendar([a, b, c], org_id: ctx.org, name: "What's on")

      assert ics =~ "X-WR-CALNAME:What's on"
      assert ics |> String.split("BEGIN:VEVENT") |> length() == 3
      refute ics =~ "SUMMARY:No schedule"
    end

    test "filename/1 is safe for a Content-Disposition header", ctx do
      event = event!(ctx, %{"when" => %{"start" => "2026-03-15T19:00"}}, %{slug: "a-gig-2026"})
      assert ICS.filename(event) == "a-gig-2026.ics"
    end
  end

  describe "schema.org" do
    test "a document whose type declares Event fires an Event node with dates", ctx do
      add_recurrence(ctx.td, ctx.admin)
      CMS.update_type_definition!(ctx.td, %{schema_org_type: "Event"}, actor: ctx.admin)

      event =
        event!(ctx, %{
          "when" => %{
            "start" => "2026-03-15T19:00",
            "end" => "2026-03-15T21:00",
            "time_zone" => @london
          },
          "repeats" => %{"rrule" => "FREQ=WEEKLY;BYDAY=SU"}
        })

      node = KilnCMS.Firing.SchemaOrg.main_node(event, "the body")

      assert node["@type"] == "Event"
      # An Event carries `name`, and neither `articleBody` nor `text` — those
      # are CreativeWork properties, and emitting one makes the node invalid
      # rather than merely verbose.
      assert node["name"] == "A gig"
      refute Map.has_key?(node, "articleBody")
      refute Map.has_key?(node, "text")

      dates = Events.schema_org_schedule(event)

      assert dates["startDate"] == "2026-03-15T19:00:00Z"
      assert dates["endDate"] == "2026-03-15T21:00:00Z"

      # The *rule*, not a window of expanded instances: expansion is correct
      # only at the moment it is fired, and a fired artifact outlives that.
      assert dates["eventSchedule"] == %{
               "@type" => "Schedule",
               "repeatFrequency" => "RRULE:FREQ=WEEKLY;BYDAY=SU"
             }
    end

    test "a type declaring Event with no schedule field fires no dates", ctx do
      other =
        CMS.create_type_definition!(
          %{
            name: "n#{System.unique_integer([:positive])}",
            label: "N",
            schema_org_type: "Event"
          },
          actor: ctx.admin
        )

      entry =
        CMS.create_entry!(
          %{
            title: "A thing",
            slug: "ne-#{System.unique_integer([:positive])}",
            type_definition_id: other.id
          },
          actor: ctx.admin
        )

      # Allowed, not an error: the type is what an operator says it is.
      assert KilnCMS.Firing.SchemaOrg.main_node(entry, "")["@type"] == "Event"
      assert Events.schema_org_schedule(entry) == %{}
    end
  end
end
