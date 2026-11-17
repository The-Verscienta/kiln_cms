defmodule KilnCMS.Backups.UploadPoliciesTest do
  @moduledoc """
  Who may touch a resumable backup upload (#2223): only the `:backups`
  system actor. System-only, like the backup notices: a platform admin is
  refused like everyone else, and so is another subsystem's system actor.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.{OrgMembership, User}
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Upload
  alias KilnCMS.SystemActor

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "upload-#{role}-#{System.unique_integer([:positive])}@example.com",
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
      SystemActor.new(:publishing)
    ]

  defp attrs(name \\ "kiln-db-20260101-000000.dump") do
    %{
      destination_key: "dest:#{Ecto.UUID.generate()}|0123456789abcdef",
      destination_id: Ecto.UUID.generate(),
      subdir: "db",
      name: name,
      stamp: "20260101-000000",
      bytes: 10,
      sha256: String.duplicate("a", 64),
      checkpoint: %{"upload_id" => "u1"},
      owner_job_id: 7,
      owner_attempt: 1
    }
  end

  defp open!(attrs), do: Backups.open_backup_upload!(attrs, actor: Backups.system())

  test "the :backups system actor opens, reads, claims, saves and closes" do
    row = open!(attrs())
    system = Backups.system()

    assert %Upload{status: :open, attempts: 1} =
             Backups.get_open_backup_upload!(row.destination_key, "db", row.name,
               actor: system,
               authorize_with: :error
             )

    assert {:ok, row} = Backups.claim_backup_upload(row, 7, 2, actor: system)
    assert row.attempts == 2

    assert {:ok, _} =
             Backups.save_backup_upload_checkpoint(
               row,
               %{job_id: 7, attempt: 2, checkpoint: %{"offset" => 3}, bytes_done: 3},
               actor: system
             )

    assert {:ok, %Upload{status: :completed}} =
             Backups.complete_backup_upload(row, 7, 2, actor: system)

    assert [_] = Backups.list_backup_uploads!(actor: system, authorize_with: :error)
  end

  test "everyone else, platform admin included, is refused every action" do
    row = open!(attrs())

    for actor <- refused_actors() do
      who = inspect(actor && Map.get(actor, :role, actor))
      opts = [actor: actor]

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.list_backup_uploads(actor: actor, authorize_with: :error),
             "read must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.get_open_backup_upload(row.destination_key, "db", row.name,
                 actor: actor,
                 authorize_with: :error
               ),
             "open_for must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.list_owed_backup_uploads(row.destination_key, DateTime.utc_now(),
                 actor: actor,
                 authorize_with: :error
               ),
             "owed must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.open_backup_upload(attrs("kiln-db-20260102-000000.dump"), opts),
             "open must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} = Backups.claim_backup_upload(row, 8, 1, opts),
             "claim must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.save_backup_upload_checkpoint(
                 row,
                 %{job_id: 7, attempt: 1, checkpoint: %{"offset" => 9}},
                 opts
               ),
             "save_checkpoint must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.note_backup_upload_error(
                 row,
                 %{job_id: 7, attempt: 1, last_error: "x"},
                 opts
               ),
             "note_error must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} = Backups.complete_backup_upload(row, 7, 1, opts),
             "complete must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.abandon_backup_upload(
                 row,
                 %{expected_status: :open, job_id: 7, attempt: 1},
                 opts
               ),
             "abandon must refuse #{who}"

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.mark_backup_upload_aborted(
                 row,
                 %{expected_status: :open, job_id: 7, attempt: 1},
                 opts
               ),
             "mark_aborted must refuse #{who}"

      assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Forbidden{} | _]} =
               Backups.purge_backup_uploads(DateTime.add(DateTime.utc_now(), 1, :day),
                 actor: actor,
                 bulk_options: [return_errors?: true]
               ),
             "purge must refuse #{who}"
    end

    assert [%Upload{status: :open, owner_job_id: 7, owner_attempt: 1, checkpoint: checkpoint}] =
             Backups.list_backup_uploads!(actor: Backups.system())

    assert checkpoint == %{"upload_id" => "u1"}
  end

  test "one open upload per file and destination; a closed one doesn't count" do
    first = open!(attrs())
    same = %{attrs() | destination_key: first.destination_key}

    assert {:error, %Ash.Error.Invalid{}} =
             Backups.open_backup_upload(same, actor: Backups.system())

    Backups.complete_backup_upload!(first, 7, 1, actor: Backups.system())
    assert %Upload{status: :open} = open!(same)
  end
end
