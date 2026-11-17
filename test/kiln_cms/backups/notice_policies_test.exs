defmodule KilnCMS.Backups.NoticePoliciesTest do
  @moduledoc """
  Who may touch a backup notice (#2487): only the `:backups` system actor.

  System-only, like the node heartbeats: people see notices through
  `KilnCMS.Backups.status/0`, which reads as the system actor for pages that
  already checked for a platform admin. So a platform admin is refused here
  like everyone else.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Notice
  alias KilnCMS.SystemActor
  alias KilnCMS.Types.UnknownAtom

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "notice-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # An admin of the default org who is not a platform admin.
  defp site_admin do
    editor = user(:editor)

    Ash.Seed.seed!(OrgMembership, %{
      organization_id: KilnCMS.Accounts.default_org_id(),
      user_id: editor.id,
      role: :admin
    })

    editor
  end

  defp refused_actors,
    do: [
      user(:admin),
      user(:editor),
      user(:viewer),
      site_admin(),
      nil,
      SystemActor.new(:security)
    ]

  defp attrs(scope \\ "local") do
    %{
      kind: :retention,
      scope: scope,
      outcome: :skipped,
      reason: "couldn't read the backup history",
      at: DateTime.utc_now()
    }
  end

  defp report!(attrs), do: Backups.report_backup_notice!(attrs, actor: Backups.system())

  test "the :backups system actor reads, reports and clears" do
    report!(attrs())

    assert [%Notice{kind: :retention, scope: "local", outcome: :skipped}] =
             Backups.list_backup_notices!(actor: Backups.system(), authorize_with: :error)

    assert %Ash.BulkResult{status: :success} =
             Backups.clear_backup_notices(:retention, "local",
               actor: Backups.system(),
               bulk_options: [return_errors?: true]
             )

    assert Backups.list_backup_notices!(actor: Backups.system()) == []
  end

  test "everyone else, platform admin included, is refused every action" do
    report!(attrs())

    for actor <- refused_actors() do
      who = inspect(actor && Map.get(actor, :role, actor))

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.list_backup_notices(actor: actor, authorize_with: :error),
             "read must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.report_backup_notice(attrs("local:#{Ash.UUID.generate()}"), actor: actor),
             "report must refuse #{who}"

      assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Forbidden{} | _]} =
               Backups.clear_backup_notices(:retention, "local",
                 actor: actor,
                 bulk_options: [return_errors?: true]
               ),
             "clear must refuse #{who}"
    end

    assert [%Notice{scope: "local"}] = Backups.list_backup_notices!(actor: Backups.system())
  end

  test "a report upserts on {kind, scope}: one row, the later values" do
    report!(attrs())

    report!(%{
      attrs()
      | outcome: :stopped,
        reason: "couldn't delete kiln-db-x.dump (:eacces)"
    })

    report!(%{attrs() | kind: :held_deleted, outcome: nil})

    notices = Backups.list_backup_notices!(actor: Backups.system())
    assert length(notices) == 2

    assert %Notice{outcome: :stopped, reason: "couldn't delete kiln-db-x.dump (:eacces)"} =
             Enum.find(notices, &(&1.kind == :retention))
  end

  test "clear removes only the scope and kind it names" do
    report!(attrs("local"))
    report!(attrs("dest:a"))
    report!(%{attrs("local") | kind: :held_deleted, outcome: nil})

    Backups.clear_backup_notices!(:retention, "local", actor: Backups.system())

    assert [{:held_deleted, "local"}, {:retention, "dest:a"}] =
             Backups.list_backup_notices!(actor: Backups.system())
             |> Enum.map(&{&1.kind, &1.scope})
             |> Enum.sort()
  end

  test "the reason is redacted and capped, the label too, and units keep ten" do
    report!(%{
      attrs("dest:x")
      | reason: "rclone: s3://user:hunter2secret@bucket " <> String.duplicate("x", 900)
    })

    report!(
      %{
        attrs("local")
        | kind: :held_deleted,
          outcome: nil
      }
      |> Map.put(:units, for(i <- 10..21, do: "db:202601#{i}-000000"))
    )

    [held, retention] =
      Backups.list_backup_notices!(actor: Backups.system()) |> Enum.sort_by(& &1.kind)

    refute retention.reason =~ "hunter2secret"
    assert String.length(retention.reason) == 500
    assert length(held.units) == 10
  end

  test "a kind a newer release wrote loads instead of breaking the read" do
    Ash.Seed.seed!(Notice, attrs("local:newer"))

    KilnCMS.Repo.query!("UPDATE backup_notices SET kind = 'from_the_future'")

    assert [%Notice{kind: %UnknownAtom{value: "from_the_future"}}] =
             Backups.list_backup_notices!(actor: Backups.system())
  end
end
