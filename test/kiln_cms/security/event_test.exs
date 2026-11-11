defmodule KilnCMS.Security.EventTest do
  @moduledoc """
  The security audit log resource and domain (#2241): append-only for people,
  org-admin-only reads, tenant isolation, the metadata allowlist, and the
  system-actor erasure and retention sweeps (which fail closed).
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  @moduletag :capture_log

  alias KilnCMS.Security
  alias KilnCMS.Security.Event

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sec-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp record!(attrs \\ %{}, tenant \\ nil) do
    Security.record!(Map.merge(%{type: :sign_in}, attrs),
      actor: Security.system(),
      tenant: tenant || org_id()
    )
  end

  # Rows read around every policy, so assertions never depend on the grant
  # under test.
  defp stored(tenant \\ nil) do
    Event
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, tenant: tenant || org_id())
  end

  defp seed_at(attrs, days_ago) do
    Ash.Seed.seed!(
      Event,
      Map.merge(
        %{
          org_id: org_id(),
          type: :sign_in,
          inserted_at: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
        },
        attrs
      )
    )
  end

  describe "record" do
    test "stores the event under the tenant, with the typed fields" do
      actor = user(:editor)

      event =
        record!(%{
          type: :passkey_added,
          actor_id: actor.id,
          actor_label: actor.email |> to_string(),
          target_type: "user",
          target_id: actor.id,
          ip: "203.0.113.7",
          user_agent: "Mozilla/5.0",
          metadata: %{"name" => "YubiKey"}
        })

      assert event.org_id == org_id()
      assert event.type == :passkey_added
      assert event.metadata == %{"name" => "YubiKey"}
      assert %DateTime{} = event.inserted_at
    end

    test "metadata is cut to the type's allowlist, scalars only, length-capped" do
      event =
        record!(%{
          type: :api_key_created,
          metadata: %{
            "name" => String.duplicate("a", 500),
            "scope" => :read,
            "token" => "kiln_secret",
            "nested" => %{"a" => 1},
            password: "hunter2"
          }
        })

      assert Map.keys(event.metadata) |> Enum.sort() == ["name", "scope"]
      assert String.length(event.metadata["name"]) == Event.max_metadata_value()
      assert event.metadata["scope"] == "read"
    end

    test "an unknown type is refused" do
      assert {:error, %Ash.Error.Invalid{}} =
               Security.record(%{type: :nope}, actor: Security.system(), tenant: org_id())
    end

    test "org_id cannot be supplied" do
      assert {:error, %Ash.Error.Invalid{}} =
               Security.record(%{type: :sign_in, org_id: Ash.UUID.generate()},
                 actor: Security.system(),
                 tenant: org_id()
               )
    end

    test "every type has an allowlist entry" do
      for type <- Event.types(), do: assert(is_list(Event.metadata_keys(type)))
      assert length(Event.types()) == 31
    end
  end

  describe "policies" do
    test "an admin reads the log" do
      event = record!()
      admin = user(:admin)

      assert event.id in (Security.list_events!(actor: admin, tenant: org_id())
                          |> Enum.map(& &1.id))

      assert Security.get_event!(event.id, actor: admin, tenant: org_id()).id == event.id
    end

    for role <- [:editor, :viewer] do
      test "a #{role} reads nothing and is refused when asking for the refusal" do
        record!()
        actor = user(unquote(role))

        assert {:ok, []} = Security.list_events(actor: actor, tenant: org_id())

        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.list_events(actor: actor, tenant: org_id(), authorize_with: :error)
      end
    end

    test "an anonymous caller reads nothing" do
      record!()
      assert {:ok, []} = Security.list_events(tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.list_events(tenant: org_id(), authorize_with: :error)
    end

    test "no person, admin included, can record, scrub or delete an event" do
      event = record!()

      for actor <- [user(:admin), user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.record(%{type: :sign_in}, actor: actor, tenant: org_id())

        refute Ash.can?({Event, :record}, actor, tenant: org_id())
        refute Ash.can?({event, :anonymize_actor}, actor, tenant: org_id())
        refute Ash.can?({event, :prune}, actor, tenant: org_id())
      end

      assert length(stored()) == 1
    end

    test "the system actor cannot list the whole log" do
      record!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.list_events(
                 actor: Security.system(),
                 tenant: org_id(),
                 authorize_with: :error
               )
    end

    test "an admin of another org sees nothing here, and its own events stay its own" do
      other = org("sec-other")
      mine = record!(%{type: :sign_in_locked})
      theirs = record!(%{type: :sign_in_failed}, other.id)

      # A viewer account who administers only `other`.
      outsider = user(:viewer)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: other.id,
        user_id: outsider.id,
        role: :admin
      })

      assert [%{id: id}] = Security.list_events!(actor: outsider, tenant: other.id)
      assert id == theirs.id

      assert {:ok, []} = Security.list_events(actor: outsider, tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.list_events(actor: outsider, tenant: org_id(), authorize_with: :error)

      refute mine.id in Enum.map(
               Security.list_events!(actor: outsider, tenant: other.id),
               & &1.id
             )
    end
  end

  describe "list filters" do
    test "by type, actor and date range, newest first" do
      a = Ash.UUID.generate()
      old = seed_at(%{type: :sign_in, actor_id: a}, 10)
      mid = seed_at(%{type: :sign_in_failed, actor_id: a}, 5)
      new = seed_at(%{type: :sign_in, actor_id: Ash.UUID.generate()}, 1)
      admin = user(:admin)

      list =
        &(Security.list_events!(&1, actor: admin, tenant: org_id()) |> Enum.map(fn e -> e.id end))

      assert list.(%{}) == [new.id, mid.id, old.id]
      assert list.(%{type: :sign_in}) == [new.id, old.id]
      assert list.(%{actor_id: a}) == [mid.id, old.id]

      assert list.(%{since: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)}) == [
               new.id,
               mid.id
             ]

      assert list.(%{until: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)}) == [old.id]
    end
  end

  describe "anonymize_actor/1" do
    test "scrubs the user's identity from events they acted in or are the target of" do
      gone = Ash.UUID.generate()
      admin_id = Ash.UUID.generate()

      acted =
        record!(%{
          type: :passkey_added,
          actor_id: gone,
          actor_label: "gone@example.com",
          ip: "198.51.100.4",
          user_agent: "UA",
          metadata: %{"name" => "my laptop"}
        })

      targeted =
        record!(%{
          type: :role_granted,
          actor_id: admin_id,
          actor_label: "admin@example.com",
          target_type: "user",
          target_id: gone,
          ip: "192.0.2.9",
          metadata: %{"role" => "editor"}
        })

      untouched = record!(%{type: :sign_in, actor_id: admin_id, ip: "192.0.2.9"})

      assert :ok = Security.anonymize_actor(gone)
      rows = Map.new(stored(), &{&1.id, &1})

      a = rows[acted.id]

      assert {a.actor_id, a.actor_label, a.ip, a.user_agent, a.metadata} ==
               {nil, nil, nil, nil, %{}}

      assert a.type == :passkey_added

      t = rows[targeted.id]
      assert t.target_id == nil and t.metadata == %{}

      assert t.actor_id == admin_id and t.actor_label == "admin@example.com" and
               t.ip == "192.0.2.9"

      u = rows[untouched.id]
      assert {u.actor_id, u.ip} == {admin_id, "192.0.2.9"}
    end

    test "reaches every org, and is idempotent" do
      other = org("sec-erase")
      gone = Ash.UUID.generate()
      record!(%{actor_id: gone, ip: "192.0.2.1"})
      record!(%{actor_id: gone, ip: "192.0.2.2"}, other.id)

      assert :ok = Security.anonymize_actor(gone)
      assert :ok = Security.anonymize_actor(gone)

      assert Enum.all?(stored() ++ stored(other.id), &(&1.actor_id == nil and &1.ip == nil))
    end

    test "fails closed when the grant is gone: raises, scrubs nothing" do
      gone = Ash.UUID.generate()
      record!(%{actor_id: gone, ip: "192.0.2.1"})

      assert_raise RuntimeError, ~r/security anonymize_actor incomplete/, fn ->
        Security.with_actor(nil, fn -> Security.anonymize_actor(gone) end)
      end

      assert [%{actor_id: ^gone, ip: "192.0.2.1"}] = stored()
    end
  end

  describe "prune/1" do
    test "deletes events older than the window and keeps the rest" do
      old = seed_at(%{}, 400)
      edge = seed_at(%{}, 366)
      fresh = seed_at(%{}, 10)

      assert {:ok, 2} = Security.prune(org_id: org_id(), retention_days: 365)
      assert [%{id: id}] = stored()
      assert id == fresh.id
      refute old.id == id or edge.id == id
    end

    test "retention_days 0 keeps everything" do
      seed_at(%{}, 4000)
      assert {:ok, 0} = Security.prune(org_id: org_id(), retention_days: 0)
      assert length(stored()) == 1
    end

    test "chunks through a backlog larger than one chunk" do
      for n <- 1..7, do: seed_at(%{}, 100 + n)
      assert {:ok, 7} = Security.prune(org_id: org_id(), retention_days: 30, chunk_size: 3)
      assert stored() == []
    end

    test "only the named org is pruned" do
      other = org("sec-prune")
      seed_at(%{}, 100)
      seed_at(%{org_id: other.id}, 100)

      assert {:ok, 1} = Security.prune(org_id: other.id, retention_days: 30)
      assert length(stored()) == 1
      assert stored(other.id) == []
    end

    test "fails closed when the grant is gone: raises, deletes nothing" do
      seed_at(%{}, 400)

      assert_raise Ash.Error.Forbidden, fn ->
        Security.with_actor(nil, fn -> Security.prune(org_id: org_id(), retention_days: 30) end)
      end

      assert length(stored()) == 1
    end
  end

  # A type a newer release added, read by this one during a rolling deploy or
  # after a rollback: it must neither break the log nor escape erasure.
  describe "a type a newer release recorded (#2509)" do
    alias KilnCMS.NewerReleaseRows
    alias KilnCMS.Types.UnknownAtom

    test "lists, as an UnknownAtom keeping the stored name, beside known events" do
      known = record!(%{type: :sign_in})
      unknown_id = NewerReleaseRows.security_event!(%{actor_label: "new@example.com"})
      admin = user(:admin)
      name = NewerReleaseRows.unknown()

      events = Security.list_events!(%{}, actor: admin, tenant: org_id())

      assert %{type: %UnknownAtom{value: ^name}, actor_label: "new@example.com"} =
               Enum.find(events, &(&1.id == unknown_id))

      assert %{type: :sign_in} = Enum.find(events, &(&1.id == known.id))
    end

    test "a known type filter leaves it out, and paging walks past it" do
      first = seed_at(%{type: :sign_in}, 3)
      unknown_id = NewerReleaseRows.security_event!(%{inserted_at: days_ago(2)})
      last = seed_at(%{type: :sign_in}, 1)
      admin = user(:admin)

      assert Security.list_events!(%{type: :sign_in}, actor: admin, tenant: org_id())
             |> Enum.map(& &1.id) == [last.id, first.id]

      page = Security.list_events!(%{}, actor: admin, tenant: org_id(), page: [limit: 1])
      page2 = Ash.page!(page, :next)
      page3 = Ash.page!(page2, :next)

      assert Enum.map([page, page2, page3], fn p -> hd(p.results).id end) ==
               [last.id, unknown_id, first.id]
    end

    test "recording one is still refused" do
      for type <- [NewerReleaseRows.unknown(), %UnknownAtom{value: "sign_in"}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Security.record(%{type: type}, actor: Security.system(), tenant: org_id())
      end
    end

    test "anonymize_actor/1 scrubs it and keeps its type" do
      gone = Ash.UUID.generate()

      acted =
        NewerReleaseRows.security_event!(%{
          actor_id: gone,
          actor_label: "gone@example.com",
          ip: "198.51.100.4",
          user_agent: "UA",
          metadata: %{"name" => "my laptop"}
        })

      targeted =
        NewerReleaseRows.security_event!(%{
          target_type: "user",
          target_id: gone,
          metadata: %{"role" => "editor"}
        })

      assert :ok = Security.anonymize_actor(gone)

      a = NewerReleaseRows.stored_row("security_events", acted)

      assert {a["actor_id"], a["actor_label"], a["ip"], a["user_agent"], a["metadata"]} ==
               {nil, nil, nil, nil, %{}}

      assert a["type"] == NewerReleaseRows.unknown()

      t = NewerReleaseRows.stored_row("security_events", targeted)
      assert {t["target_id"], t["metadata"], t["type"]} == {nil, %{}, NewerReleaseRows.unknown()}
    end

    test "prune/1 deletes it once it is past the window" do
      old = NewerReleaseRows.security_event!(%{inserted_at: days_ago(400)})
      fresh = seed_at(%{}, 10)

      assert {:ok, 1} = Security.prune(org_id: org_id(), retention_days: 365)
      assert [%{id: id}] = stored()
      assert id == fresh.id and id != old
    end

    defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  describe "the security alerts' reads (#2245)" do
    test "the alerts actor reads the one event an alert names, and a window of types" do
      old = seed_at(%{type: :sign_in_locked}, 2)
      locked = record!(%{type: :sign_in_locked})
      _other_type = record!(%{type: :sign_in})
      other_org = record!(%{type: :sign_in_locked}, org("alerts-window").id)
      system = Security.alerts_system()

      assert {:ok, %{id: id}} =
               Security.get_event_for_alert(locked.id,
                 actor: system,
                 tenant: org_id(),
                 authorize_with: :error
               )

      assert id == locked.id

      assert {:error, _} =
               Security.get_event_for_alert(other_org.id, actor: system, tenant: org_id())

      since = DateTime.add(DateTime.utc_now(), -3_600, :second)
      until = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, events} =
               Security.alert_window_events([:sign_in_locked], since, until,
                 actor: system,
                 tenant: org_id(),
                 authorize_with: :error
               )

      ids = Enum.map(events, & &1.id)
      assert locked.id in ids
      refute old.id in ids
      refute other_org.id in ids
      assert Enum.all?(events, &(&1.type == :sign_in_locked))

      # `until` is exclusive.
      assert {:ok, []} =
               Security.alert_window_events([:sign_in_locked], since, since,
                 actor: system,
                 tenant: org_id()
               )
    end

    test "the alerts actor is admitted to those two reads and nothing else" do
      record!(%{type: :sign_in_locked})
      system = Security.alerts_system()

      assert {:ok, []} = Security.list_events(actor: system, tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.record(%{type: :sign_in}, actor: system, tenant: org_id())

      # The audit log's own actor is not admitted to the alerts' reads.
      assert {:ok, []} =
               Security.alert_window_events(
                 [:sign_in_locked],
                 DateTime.add(DateTime.utc_now(), -3_600, :second),
                 DateTime.add(DateTime.utc_now(), 60, :second),
                 actor: Security.system(),
                 tenant: org_id()
               )
    end

    test "an org admin may read them too; an editor may not" do
      event = record!(%{type: :sign_in_locked})

      assert {:ok, _} =
               Security.get_event_for_alert(event.id, actor: user(:admin), tenant: org_id())

      assert {:error, _} =
               Security.get_event_for_alert(event.id, actor: user(:editor), tenant: org_id())
    end

    test "metadata the alerts read survives the allowlist" do
      event =
        record!(%{
          type: :role_revoked,
          metadata: %{"role" => "admin", "level" => "site", "change" => "removed", "x" => "y"}
        })

      assert event.metadata == %{"role" => "admin", "level" => "site", "change" => "removed"}

      reuse =
        record!(%{type: :api_key_reuse_detected, metadata: %{"name" => "ci", "revoked" => 2}})

      assert reuse.metadata == %{"name" => "ci", "revoked" => 2}
    end
  end
end
