defmodule KilnCMS.Security.InstanceEventTest do
  @moduledoc """
  The instance security log (#2541): events about the installation, readable by
  platform admins only. A site admin of the default site (by membership, not a
  platform admin) is refused, and so is everyone else; no person writes; the
  recorder routes `scope: :instance`; erasure and retention reach it and fail
  closed.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Security
  alias KilnCMS.Security.Event
  alias KilnCMS.Security.InstanceEvent
  alias KilnCMS.Security.Recorder

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "inst-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  # An admin of the default site by membership; their own role is `:editor`,
  # so they are not a platform admin.
  defp default_site_admin do
    user = user(:editor)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: Accounts.default_org_id(),
      role: :admin
    })

    user
  end

  defp record!(attrs \\ %{}) do
    Security.record_instance_event!(Map.merge(%{type: :backup_canceled}, attrs),
      actor: Security.system()
    )
  end

  defp stored do
    InstanceEvent |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!(authorize?: false)
  end

  defp list!(actor), do: Security.list_instance_events!(actor: actor, authorize_with: :error)

  defp seed_at(attrs, days_ago) do
    Ash.Seed.seed!(
      InstanceEvent,
      Map.merge(
        %{
          type: :backup_canceled,
          inserted_at: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
        },
        attrs
      )
    )
  end

  describe "reading" do
    test "a platform admin reads the log" do
      event = record!(%{actor_label: "ops@example.com"})
      assert [%{id: id}] = Enum.filter(list!(user(:admin)), &(&1.id == event.id))
      assert id == event.id
    end

    test "a temporary platform admin grant reads it until it expires" do
      record!()

      live = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(3600)})
      assert list!(live) != []

      expired = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(-1)})

      assert_raise Ash.Error.Forbidden, fn -> list!(expired) end
    end

    test "the default site's admin, an editor, a viewer and nobody are refused" do
      record!(%{actor_label: "ops@example.com"})

      for actor <- [default_site_admin(), user(:editor), user(:viewer), nil] do
        assert_raise Ash.Error.Forbidden, fn -> list!(actor) end

        # A filter-authorized read shows nothing rather than the rows.
        assert Security.list_instance_events!(actor: actor) == []
      end
    end

    test "the system actor may not list the log" do
      record!()
      assert_raise Ash.Error.Forbidden, fn -> list!(Security.system()) end
    end
  end

  describe "writing" do
    test "no person records an event, a platform admin included" do
      for actor <- [user(:admin), default_site_admin(), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.record_instance_event(%{type: :backup_canceled}, actor: actor)
      end

      assert stored() == []
    end

    test "metadata is held to the type's allowlist" do
      event =
        record!(%{metadata: %{"stamp" => "20261110-120000", "step" => "dump", "secret" => "x"}})

      assert event.metadata == %{"stamp" => "20261110-120000", "step" => "dump"}
    end

    test "a site log no longer takes backup_canceled" do
      assert {:error, %Ash.Error.Invalid{}} =
               Security.record(%{type: :backup_canceled},
                 actor: Security.system(),
                 tenant: Accounts.default_org_id()
               )

      refute :backup_canceled in Event.types()
      assert :backup_canceled in InstanceEvent.types()
    end
  end

  describe "Recorder scope: :instance" do
    test "writes to the instance log, never a site's, with no tenant needed" do
      actor = user(:admin)

      assert {:ok, %InstanceEvent{} = event} =
               Recorder.record(:backup_canceled,
                 scope: :instance,
                 user: actor,
                 target_type: "backup_run",
                 target_id: Ecto.UUID.generate(),
                 metadata: %{"stamp" => "20261110-120000"},
                 request: %{ip: "203.0.113.9", user_agent: "UA"}
               )

      assert event.actor_id == actor.id
      assert event.actor_label == to_string(actor.email)
      assert event.ip == "203.0.113.9"

      site_rows =
        Event |> Ash.read!(authorize?: false, tenant: Accounts.default_org_id())

      refute Enum.any?(site_rows, &(&1.id == event.id))
    end

    test "a sampled type is never an instance event" do
      assert_raise ArgumentError, fn ->
        Recorder.record_sampled(:sign_in_failed, scope: :instance)
      end
    end

    test "a mistyped scope raises instead of skipping the event" do
      assert_raise ArgumentError, ~r/scope/, fn ->
        Recorder.record(:backup_canceled, scope: :instnace)
      end
    end

    test "Changes.Record refuses an unknown scope" do
      assert {:error, message} =
               KilnCMS.Security.Changes.Record.init(type: :backup_canceled, scope: :instnace)

      assert message =~ "scope"
    end
  end

  describe "erasure" do
    test "anonymize_actor/1 scrubs the instance log too" do
      gone = user(:admin)
      record!(%{actor_id: gone.id, actor_label: "gone@example.com", ip: "203.0.113.1"})
      other = record!(%{actor_label: "kept@example.com"})

      assert :ok = Security.anonymize_actor(gone.id)

      [scrubbed] = Enum.reject(stored(), &(&1.id == other.id))
      assert scrubbed.actor_id == nil
      assert scrubbed.actor_label == nil
      assert scrubbed.ip == nil
      assert scrubbed.metadata == %{}
      assert Enum.find(stored(), &(&1.id == other.id)).actor_label == "kept@example.com"
    end

    test "fails closed when the grant is gone" do
      gone = user(:admin)
      record!(%{actor_id: gone.id})

      assert_raise RuntimeError, ~r/instance/, fn ->
        Security.with_actor(nil, fn -> Security.anonymize_actor(gone.id) end)
      end
    end
  end

  describe "retention" do
    test "prune_instance/1 deletes events past the window only" do
      old = seed_at(%{}, 40)
      new = seed_at(%{}, 5)

      assert {:ok, 1} = Security.prune_instance(retention_days: 30)
      ids = Enum.map(stored(), & &1.id)
      refute old.id in ids
      assert new.id in ids
    end

    test "0 keeps everything" do
      seed_at(%{}, 4000)
      assert {:ok, 0} = Security.prune_instance(retention_days: 0)
      assert length(stored()) == 1
    end

    test "fails closed when the grant is gone" do
      seed_at(%{}, 40)

      assert_raise Ash.Error.Forbidden, fn ->
        Security.with_actor(nil, fn -> Security.prune_instance(retention_days: 30) end)
      end
    end

    test "the window defaults to 365 days" do
      assert Security.instance_retention_days() == 365
    end
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
