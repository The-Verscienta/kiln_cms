defmodule KilnCMS.Staging.PluginScrubTest do
  @moduledoc """
  The staging scrub's rule for plugin and overlay tables (#2975): each is
  purged, rewritten or kept as its plugin declares in
  `c:Kiln.Plugin.staging_scrub/0`, and anything the scrub cannot account for
  stops it before it changes a row. See `KilnCMS.Staging.PluginScrub`.

  The tables are `KilnCMS.PluginScrubFixtures`', created inside each test's
  sandbox. The plugins are passed in (`plugins:`), never configured.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Billing
  alias KilnCMS.PluginScrubFixtures, as: F
  alias KilnCMS.Repo
  alias KilnCMS.Staging
  alias KilnCMS.Staging.PluginScrub
  alias KilnCMS.Staging.Scrub

  import KilnCMS.PluginScrubFixtures, only: [create_table!: 1, create_table!: 2]

  defmodule VersionlessPlugin do
    use Kiln.Plugin
    def name, do: "versionless"
    def domains, do: [F.Domain]
    def staging_scrub, do: [{:purge, F.Booking}]
  end

  defmodule SilentPlugin do
    use Kiln.Plugin
    def name, do: "silent"
    def domains, do: [F.Domain]
  end

  defmodule RaisingPlugin do
    use Kiln.Plugin
    def name, do: "raising"
    def staging_scrub, do: raise("no declaration today")
  end

  defmodule NonListPlugin do
    use Kiln.Plugin
    def name, do: "non_list"
    def staging_scrub, do: %{purge: F.Booking}
  end

  defmodule MalformedPlugin do
    use Kiln.Plugin
    def name, do: "malformed"
    def domains, do: [F.Domain]
    def staging_scrub, do: [{:purge, F.BookingNote}, {:drop, F.Venue}]
  end

  defmodule ClaimsCorePlugin do
    use Kiln.Plugin
    def name, do: "claims_core"
    def domains, do: [KilnCMS.Accounts]
    def staging_scrub, do: [{:keep, KilnCMS.Accounts.User, "we need the real accounts"}]
  end

  defmodule NotOwnedPlugin do
    use Kiln.Plugin
    def name, do: "not_owned"
    def staging_scrub, do: [{:purge, F.Venue}, {:purge, F.OverlayThing}, {:purge, String}]
  end

  defmodule BadRewritePlugin do
    use Kiln.Plugin
    def name, do: "bad_rewrite"
    def domains, do: [F.Domain]

    def staging_scrub,
      do: [
        {:rewrite, F.Booking, set: [id: Ecto.UUID.generate()]},
        {:rewrite, F.Booking, set: [code: "same-for-all"]},
        {:rewrite, F.Tenanted, set: [org_id: Ecto.UUID.generate()]},
        {:rewrite, F.BookingNote, set: [booking_id: nil]},
        {:rewrite, F.Booking, set: [nope: 1]},
        {:rewrite, F.Booking, set: [name: nil]},
        {:rewrite, F.Booking, set: [guests: "many"]},
        {:rewrite, F.Venue, set: []},
        {:rewrite, F.Venue, set: "name"},
        {:keep, F.Event, "  "}
      ]
  end

  defmodule DuplicatePlugin do
    use Kiln.Plugin
    def name, do: "duplicate"
    def domains, do: [F.Domain]
    def staging_scrub, do: [{:purge, F.Venue}, {:keep, F.Venue, "or keep it?"}]
  end

  defmodule KeepsReferrerPlugin do
    use Kiln.Plugin
    def name, do: "keeps_referrer"
    def domains, do: [F.Domain]

    def staging_scrub,
      do: [
        {:purge, F.Booking},
        {:purge, F.Booking.Version},
        {:keep, F.BookingNote, "notes about the venue"},
        {:keep, F.Venue, "opening hours"}
      ]
  end

  defmodule ParentFirstPlugin do
    use Kiln.Plugin
    def name, do: "parent_first"
    def domains, do: [F.Domain]

    def staging_scrub,
      do: [
        {:purge, F.Booking},
        {:purge, F.BookingNote},
        {:purge, F.Booking.Version},
        {:keep, F.Venue, "opening hours"}
      ]
  end

  defmodule ContextPlugin do
    use Kiln.Plugin
    def name, do: "context"
    def domains, do: [F.ContextDomain]
  end

  defmodule ViewPlugin do
    use Kiln.Plugin
    def name, do: "view"
    def domains, do: [F.ViewDomain]
  end

  defp uniq, do: System.unique_integer([:positive])

  defp opts(plugins, extra \\ []),
    do: Keyword.merge([plugins: plugins, ash_domains: PluginScrub.core_domains()], extra)

  defp count(table) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
    n
  end

  defp insert_booking!(email \\ "guest@example.com") do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO psf_bookings (code, email, name, guests) VALUES ($1, $2, $3, 4) RETURNING id",
        ["code-#{uniq()}", email, "Real Guest"]
      )

    id
  end

  defp booking_tables!(notes_on_delete \\ "NO ACTION") do
    create_table!("psf_bookings")
    create_table!("psf_bookings_versions")
    create_table!("psf_booking_notes", on_delete: notes_on_delete)
    create_table!("psf_venues")

    booking = insert_booking!()

    Repo.query!(
      "INSERT INTO psf_booking_notes (body, booking_id) VALUES ('allergic to nuts', $1)",
      [
        booking
      ]
    )

    Repo.query!(
      ~s|INSERT INTO psf_bookings_versions (version_source_id, changes) VALUES ($1, '{"email": "guest@example.com"}')|,
      [booking]
    )

    Repo.query!("INSERT INTO psf_venues (name) VALUES ('Main hall')")
    booking
  end

  # Rows of the core tables the refusal must leave alone: an account, its API
  # key, a queued job and the payment credentials the scrub removes first.
  defp seed_core! do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "real-#{uniq()}@example.com",
        name: "Real Person",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    expires_at = DateTime.add(DateTime.utc_now(), 86_400, :second)
    {:ok, _key} = Accounts.mint_api_key(user.id, "ci", expires_at, authorize?: false)

    %{"to" => "reader-#{uniq()}@example.com"}
    |> Oban.Job.new(worker: "KilnCMS.Mail.DeliveryWorker", queue: :mail)
    |> Repo.insert!()

    Billing.ensure_settings!()
    user
  end

  defp core_state(user) do
    %{
      user: Accounts.get_user!(user.id, authorize?: false) |> Map.take([:email, :anonymized_at]),
      api_keys: Repo.aggregate(Accounts.ApiKey, :count),
      jobs: Repo.aggregate(Oban.Job, :count),
      billing_settings: Repo.aggregate(Billing.Settings, :count)
    }
  end

  # Runs the scrub expecting a refusal matching `message`, and asserts the
  # core rows came through it unchanged.
  defp assert_refused(scrub_opts, message) do
    user = seed_core!()
    before = core_state(user)
    assert before.api_keys >= 1 and before.jobs >= 1 and before.billing_settings == 1

    error = assert_raise RuntimeError, fn -> Scrub.run(scrub_opts) end
    assert error.message =~ "Refusing to scrub"
    assert error.message =~ "Nothing has been changed"
    assert error.message =~ message

    assert core_state(user) == before
    error.message
  end

  describe "a plugin's declared tables" do
    test "are purged, rewritten and kept as declared, and counted under the plugin" do
      booking = booking_tables!()

      summary = Scrub.run(opts([F.DeclaringPlugin]))

      assert count("psf_booking_notes") == 0
      assert count("psf_bookings_versions") == 0
      assert count("psf_venues") == 1

      assert %{rows: [[code, nil, "Scrubbed guest", 0]]} =
               Repo.query!("SELECT code, email, name, guests FROM psf_bookings WHERE id = $1", [
                 booking
               ])

      assert code =~ "code-"

      assert summary[{:plugin, "booking", "psf_booking_notes"}] == 1
      assert summary[{:plugin, "booking", "psf_bookings"}] == 1
      assert summary[{:plugin, "booking", "psf_bookings_versions"}] == 1
      refute Map.has_key?(summary, {:plugin, "booking", "psf_venues"})

      # And the core scrub ran after it.
      assert summary.users_anonymized >= 0
    end

    test "a declared table that does not exist is skipped and counts 0" do
      summary = Scrub.run(opts([F.DeclaringPlugin]))

      assert summary[{:plugin, "booking", "psf_bookings"}] == 0
      assert summary[{:plugin, "booking", "psf_booking_notes"}] == 0
      assert summary[{:plugin, "booking", "psf_bookings_versions"}] == 0
    end

    test "dispositions name exactly the plugin counts the summary has" do
      booking_tables!()

      dispositions = Scrub.dispositions(opts([F.DeclaringPlugin]))

      assert dispositions["psf_bookings"] == {:scrubbed, {:plugin, "booking", "psf_bookings"}}

      assert dispositions["psf_booking_notes"] ==
               {:purged, {:plugin, "booking", "psf_booking_notes"}}

      refute Map.has_key?(dispositions, "psf_venues")
      assert Scrub.plugin_kept(opts([F.DeclaringPlugin]))["psf_venues"] =~ "opening hours"

      from_dispositions =
        dispositions |> Map.values() |> MapSet.new(fn {_kind, key} -> key end)

      from_summary =
        opts([F.DeclaringPlugin])
        |> Scrub.run()
        |> Map.delete(:admin_provisioned)
        |> Map.keys()
        |> MapSet.new()

      assert from_dispositions == from_summary
    end

    test "the report lists each plugin table after the core's counts" do
      booking_tables!()
      test = self()

      Staging.scrub!(
        opts([F.DeclaringPlugin],
          confirm?: true,
          force?: true,
          shell: &send(test, {:shell, &1})
        )
      )

      assert_received {:shell, "Scrub complete:\n" <> report}
      assert report =~ ~r/^  booking plugin, psf_bookings: +1$/m
      assert report =~ ~r/^  booking plugin, psf_booking_notes: +1$/m

      [core_part, _] = String.split(report, "booking plugin", parts: 2)
      assert core_part =~ "users anonymized"
    end

    test "report labels name the plugin and table for a plugin key" do
      assert Staging.report_label({:plugin, "booking", "psf_bookings"}) ==
               "booking plugin, psf_bookings"

      assert Staging.report_label(:api_keys_purged) == "api keys purged"
    end
  end

  describe "an undeclared table" do
    test "stops the scrub before it changes anything, core rows included" do
      booking = booking_tables!()
      create_table!("psf_undeclared")
      Repo.query!("INSERT INTO psf_undeclared (secret) VALUES ('production only')")

      message =
        assert_refused(
          opts([F.DeclaringPlugin]),
          "booking: KilnCMS.PluginScrubFixtures.Undeclared (table psf_undeclared)"
        )

      assert message =~ "{:purge, Resource}"

      # The plugin's own declared tables are untouched too.
      assert count("psf_undeclared") == 1
      assert count("psf_booking_notes") == 1

      assert %{rows: [["guest@example.com"]]} =
               Repo.query!("SELECT email FROM psf_bookings WHERE id = $1", [booking])
    end

    test "a plugin built before 1.5 declares nothing, so its tables are undeclared" do
      create_table!("psf_venues")
      assert_refused(opts([SilentPlugin]), "silent: KilnCMS.PluginScrubFixtures.Venue")
    end

    test "a version table is a table of its own" do
      create_table!("psf_bookings")
      create_table!("psf_bookings_versions")
      insert_booking!()

      assert_refused(
        opts([VersionlessPlugin]),
        "versionless: KilnCMS.PluginScrubFixtures.Booking.Version (table psf_bookings_versions)"
      )

      assert count("psf_bookings") == 1
    end

    test "an overlay domain no plugin claims is refused, with how to declare it" do
      create_table!("psf_overlay_things")

      message =
        assert_refused(
          opts([], ash_domains: PluginScrub.core_domains() ++ [F.Overlay]),
          "(no plugin): KilnCMS.PluginScrubFixtures.OverlayThing (table psf_overlay_things)"
        )

      assert message =~ "move the domain into a plugin's domains/0"
    end

    test "an unclaimed overlay domain with no tables yet does not stop the scrub" do
      assert %{users_anonymized: _} =
               Scrub.run(opts([], ash_domains: PluginScrub.core_domains() ++ [F.Overlay]))
    end

    test "a resource over a view has no rows of its own to declare" do
      create_table!("psf_view")
      assert %{users_anonymized: _} = Scrub.run(opts([ViewPlugin]))
    end
  end

  describe "content" do
    test "a content table, its history and a graduated join are kept without an entry" do
      booking_tables!()
      create_table!("psf_events")
      create_table!("psf_links")
      Repo.query!("INSERT INTO psf_events (title) VALUES ('Launch party')")
      Repo.query!("INSERT INTO psf_links (position) VALUES (0)")

      Scrub.run(opts([F.DeclaringPlugin]))

      assert count("psf_events") == 1
      assert count("psf_links") == 1

      kept = Scrub.plugin_kept(opts([F.DeclaringPlugin]))
      assert kept["psf_events"] == "content"
      assert kept["psf_links"] == "content: graduated join"
      refute Map.has_key?(kept, "psf_contacts")
    end

    test "a content table with a personal-looking column must be declared" do
      create_table!("psf_contacts")

      assert_refused(
        opts([F.DeclaringPlugin]),
        "booking: KilnCMS.PluginScrubFixtures.Contact (table psf_contacts)"
      )
    end
  end

  describe "an unusable declaration" do
    test "a callback that raises stops the scrub" do
      assert_refused(
        opts([RaisingPlugin]),
        "raising: staging_scrub/0 raised: no declaration today"
      )
    end

    test "a callback that returns something other than a list stops the scrub" do
      assert_refused(opts([NonListPlugin]), "non_list: staging_scrub/0 must return a list")
    end

    test "a malformed entry stops the scrub, though the other entry is fine" do
      create_table!("psf_bookings")
      create_table!("psf_booking_notes")

      assert_refused(
        opts([MalformedPlugin]),
        "malformed: staging_scrub/0 entry {:drop, KilnCMS.PluginScrubFixtures.Venue} is not"
      )
    end

    test "dispositions refuse it too" do
      assert_raise RuntimeError, ~r/staging_scrub\/0 raised/, fn ->
        Scrub.dispositions(opts([RaisingPlugin]))
      end
    end

    test "a plugin cannot declare a core table, even listing a core domain" do
      assert_refused(
        opts([ClaimsCorePlugin]),
        "claims_core: KilnCMS.Accounts.User is the core table users"
      )
    end

    test "a plugin can declare only resources of its own domains" do
      problems =
        PluginScrub.problems([F.DeclaringPlugin, NotOwnedPlugin], PluginScrub.core_domains())

      assert ("not_owned: KilnCMS.PluginScrubFixtures.Venue is not a resource of " <>
                "not_owned's domains/0 (it is booking's)") in problems

      assert ("not_owned: KilnCMS.PluginScrubFixtures.OverlayThing is not a resource of " <>
                "not_owned's domains/0") in problems

      assert "not_owned: String in staging_scrub/0 is not an Ash resource" in problems
    end

    test "each rewrite the scrub cannot apply safely is refused" do
      problems = PluginScrub.problems([BadRewritePlugin], PluginScrub.core_domains())
      booking = "bad_rewrite: KilnCMS.PluginScrubFixtures.Booking"

      for expected <- [
            "#{booking}.id cannot be rewritten: it is the primary key",
            "#{booking}.code cannot be rewritten: it is part of the identity :unique_code",
            "bad_rewrite: KilnCMS.PluginScrubFixtures.Tenanted.org_id cannot be rewritten: " <>
              "it is the tenant attribute",
            "bad_rewrite: KilnCMS.PluginScrubFixtures.BookingNote.booking_id cannot be " <>
              "rewritten: it is the belongs_to attribute of :booking",
            "#{booking}.nope cannot be rewritten: no such attribute",
            "#{booking}.name cannot be rewritten: it does not allow nil",
            ~s|#{booking}.guests cannot be rewritten: "many" is not a valid Ash.Type.Integer|,
            "the rewrite of KilnCMS.PluginScrubFixtures.Venue needs set: [attribute: value, ...], not []",
            ~s|the rewrite of KilnCMS.PluginScrubFixtures.Venue needs set: [attribute: value, ...], not "name"|,
            "{:keep, KilnCMS.PluginScrubFixtures.Event, reason} needs a reason"
          ] do
        assert Enum.any?(problems, &String.contains?(&1, expected)),
               "no problem saying #{inspect(expected)} in:\n#{Enum.join(problems, "\n")}"
      end

      assert_refused(opts([BadRewritePlugin]), "it is the primary key")
    end

    test "a table declared two ways is refused" do
      assert "duplicate: KilnCMS.PluginScrubFixtures.Venue has more than one staging_scrub/0 entry" in PluginScrub.problems(
               [DuplicatePlugin],
               PluginScrub.core_domains()
             )
    end

    test "a :context-multitenant table is refused: the scrub cannot reach its schemas" do
      assert_refused(
        opts([ContextPlugin]),
        "context: KilnCMS.PluginScrubFixtures.ContextThing uses :context multitenancy"
      )
    end
  end

  describe "foreign keys" do
    test "a kept table whose key would block a purge stops the scrub before it starts" do
      booking_tables!("RESTRICT")

      assert_refused(
        opts([KeepsReferrerPlugin]),
        "public.psf_booking_notes is kept, but its foreign key psf_booking_notes_booking_fkey " <>
          "to public.psf_bookings"
      )

      assert count("psf_bookings") == 1
    end

    test "a key that cascades does not" do
      booking_tables!("CASCADE")

      summary = Scrub.run(opts([KeepsReferrerPlugin]))

      assert summary[{:plugin, "keeps_referrer", "psf_bookings"}] == 1
      assert count("psf_bookings") == 0
    end

    test "a parent purged before its child is refused, with the order to use" do
      booking_tables!()

      assert_refused(
        opts([ParentFirstPlugin]),
        "public.psf_booking_notes is purged after public.psf_bookings"
      )

      assert count("psf_booking_notes") == 1
    end
  end

  describe "core domains" do
    # Listed in the module because a release strips the source paths the
    # doctor finds them by; held to the doctor's here, where the paths exist.
    test "the scrub's list is the core's domains" do
      assert PluginScrub.core_domains() == Mix.Tasks.Kiln.Plugins.Doctor.core_domains()
    end
  end

  describe "personal_column?/2" do
    test "matches addresses, networks and contacts, and nothing boolean" do
      assert PluginScrub.personal_column?("email", "text")
      assert PluginScrub.personal_column?("guest_phones", "text")
      assert PluginScrub.personal_column?("seen_from", "inet")
      assert PluginScrub.personal_column?("allowed", "_cidr")
      refute PluginScrub.personal_column?("membership", "text")
      refute PluginScrub.personal_column?("name", "text")
      refute PluginScrub.personal_column?("email", "bool")
    end
  end
end
