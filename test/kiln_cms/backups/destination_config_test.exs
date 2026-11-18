defmodule KilnCMS.Backups.DestinationConfigTest do
  @moduledoc """
  A stored backup destination (#2220): what a save accepts and refuses, how
  its secrets are kept, what the audit log and the pipeline see of it, and
  its Test.

  `async: false`: the key rotation cases swap the endpoint's
  `secret_key_base`, and the Local and env-remote cases set
  `:local_destination_roots` and `:rclone_remote` in the `KilnCMS.Backups`
  application env. All VM-global.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupDestinations
  import KilnCMS.Test.BackupSchedules

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DestinationConfig}
  alias KilnCMS.Keys.{Reencrypt, Vault}
  alias KilnCMS.Security

  @secret "fake-secret-token-123"
  @other_secret "second-secret-value-456"
  @old "old-secret-key-base-" <> String.duplicate("o", 64)
  @new "new-secret-key-base-" <> String.duplicate("n", 64)

  setup do
    backups = Application.get_env(:kiln_cms, Backups, [])
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)
    vault = Application.get_env(:kiln_cms, Vault)

    on_exit(fn ->
      Application.put_env(:kiln_cms, Backups, backups)
      Application.put_env(:kiln_cms, KilnCMSWeb.Endpoint, endpoint)

      if vault,
        do: Application.put_env(:kiln_cms, Vault, vault),
        else: Application.delete_env(:kiln_cms, Vault)
    end)

    :ok
  end

  defp backups_env(key, value) do
    Application.put_env(
      :kiln_cms,
      Backups,
      Keyword.put(Application.get_env(:kiln_cms, Backups, []), key, value)
    )
  end

  defp use_secret(secret) do
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, secret)
    )

    Application.put_env(:kiln_cms, Vault, previous_secret_key_bases: [])
  end

  # A directory listed in BACKUP_LOCAL_DESTINATION_ROOTS, under the test's
  # own tmp dir (the system tmp dir is reached through a symlink on macOS).
  defp local_root(tmp) do
    root = Path.join(tmp, "root")
    File.mkdir_p!(root)
    backups_env(:dir, Path.join(tmp, "backups"))
    backups_env(:local_destination_roots, [root])
    root
  end

  # Every error's message with its vars filled in, as the form shows it.
  defp messages(%{errors: errors}) do
    Enum.map_join(errors, "\n", fn error ->
      Enum.reduce(Map.get(error, :vars) || [], Map.get(error, :message) || "", fn {key, value},
                                                                                  acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp local(path, attrs \\ %{}) do
    Backups.create_backup_destination(
      Map.merge(
        %{
          name: "Local #{System.unique_integer([:positive])}",
          kind: "local",
          settings: %{"path" => path}
        },
        attrs
      ),
      actor: platform_admin()
    )
  end

  defp stored_ciphertext(id) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT secrets_encrypted FROM backup_destinations WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end

  defp events(type) do
    Security.list_instance_events!(actor: platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp resolve(d),
    do:
      Destination.resolve(%{
        "key" => DestinationConfig.key(d),
        "id" => d.id,
        "kind" => d.kind,
        "source" => "db"
      })

  describe "secrets" do
    test "are stored encrypted and resolve to the adapter's config" do
      d = destination!()

      refute stored_ciphertext(d.id) =~ @secret
      assert {:ok, %Config{secrets: %{"token" => @secret}, key: key}} = resolve(d)
      assert key == "dest:" <> d.id
    end

    test "never appear in inspect, the audit metadata, error messages or the log" do
      admin = platform_admin()

      log =
        capture_log(fn ->
          d = destination!(%{}, admin)
          refute inspect(d) =~ @secret
          refute inspect(Backups.get_backup_destination!(d.id, actor: admin)) =~ @secret

          {:ok, d} =
            Backups.update_backup_destination(d, %{secrets: %{"token" => @other_secret}},
              actor: admin
            )

          refute inspect(d) =~ @other_secret

          # The adapter refuses the save, naming the secret, literally and as
          # `token=…`; the error the admin sees has neither.
          assert {:error, error} =
                   Backups.update_backup_destination(
                     d,
                     %{settings: %{"mode" => "fail"}, secrets: %{"token" => @secret}},
                     actor: admin
                   )

          refute messages(error) =~ @secret
          refute Exception.message(error) =~ @secret
          refute Exception.message(error) =~ @secret
          refute inspect(error) =~ @secret
          assert messages(error) =~ "the store refused ***"

          # A failed Test, the same.
          {:ok, d} =
            Backups.update_backup_destination(
              d,
              %{settings: %{"mode" => "ok", "test_mode" => "fail"}},
              actor: admin
            )

          assert {:ok, tested} = Backups.test_destination(d.id, actor: admin)
          refute tested.last_test_error =~ @other_secret
          refute inspect(tested) =~ @other_secret

          :ok = Backups.destroy_backup_destination(d, actor: admin)
        end)

      refute log =~ @secret
      refute log =~ @other_secret

      for type <- [
            :backup_destination_created,
            :backup_destination_changed,
            :backup_destination_tested,
            :backup_destination_deleted
          ],
          event <- events(type) do
        refute inspect(event.metadata) =~ @secret
        refute inspect(event.metadata) =~ @other_secret
        # No setting's value either.
        refute inspect(event.metadata) =~ "test_mode"
      end
    end

    test "a blank secret on update keeps the stored one" do
      admin = platform_admin()
      d = destination!(%{}, admin)
      before = stored_ciphertext(d.id)

      # Each save from the row the last one returned: `:update` refuses a
      # stale record (#2952).
      Enum.reduce([%{}, %{"token" => ""}, %{"token" => "   "}, %{"token" => nil}], d, fn blank,
                                                                                         d ->
        assert {:ok, d} =
                 Backups.update_backup_destination(
                   d,
                   %{name: "Renamed #{map_size(blank)}#{inspect(blank)}", secrets: blank},
                   actor: admin
                 )

        assert stored_ciphertext(d.id) == before
        d
      end)

      assert {:ok, %Config{secrets: %{"token" => @secret}}} = resolve(d)
    end

    test "a secret given replaces the stored one, and is recorded as changed without its value" do
      admin = platform_admin()
      d = destination!(%{}, admin)

      {:ok, _} =
        Backups.update_backup_destination(d, %{secrets: %{"token" => @other_secret}},
          actor: admin
        )

      assert {:ok, %Config{secrets: %{"token" => @other_secret}}} = resolve(d)

      assert [%{metadata: %{"changed" => "secrets", "secrets_changed" => true}}] =
               events(:backup_destination_changed)
    end

    test "survive a SECRET_KEY_BASE rotation through mix kiln.vault.reencrypt" do
      use_secret(@old)
      d = destination!()

      use_secret(@new)
      assert resolve(d) == {:error, :undecryptable}

      reports = Reencrypt.run(old_secret_key_bases: [@old])

      assert %{rotated: rotated, unreadable: []} =
               Enum.find(reports, &(&1.table == "backup_destinations"))

      assert rotated >= 1
      assert {:ok, %Config{secrets: %{"token" => @secret}}} = resolve(d)
    end

    test "that no key opens resolve to :undecryptable, and a Test says so" do
      use_secret(@old)
      admin = platform_admin()
      d = destination!(%{}, admin)

      use_secret(@new)
      assert resolve(d) == {:error, :undecryptable}

      assert {:ok, tested} = Backups.test_destination(d.id, actor: admin)
      assert tested.last_test_ok == false
      assert tested.last_test_error =~ "credentials can't be decrypted"

      # Re-entering them is the way out.
      assert {:ok, _} =
               Backups.update_backup_destination(d, %{secrets: %{"token" => @other_secret}},
                 actor: admin
               )

      assert {:ok, %Config{secrets: %{"token" => @other_secret}}} = resolve(d)
    end

    test "a secret field can't be a setting, nor a setting a secret" do
      assert {:error, error} =
               Backups.create_backup_destination(
                 %{name: "x", kind: "fake", settings: %{"mode" => "ok", "token" => @secret}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "token is a secret"
      refute messages(error) =~ @secret

      assert {:error, error} =
               Backups.create_backup_destination(
                 %{
                   name: "x",
                   kind: "fake",
                   settings: %{"mode" => "ok"},
                   secrets: %{"mode" => "x"}
                 },
                 actor: platform_admin()
               )

      assert messages(error) =~ "mode is not a secret"
    end
  end

  describe "what a save refuses" do
    test "an unknown kind" do
      assert {:error, error} =
               Backups.create_backup_destination(%{name: "x", kind: "nope", settings: %{}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "no installed backup destination has this kind"
    end

    test "a smuggled \"remote\" setting, the env destination's alone" do
      for {kind, settings} <- [
            {"rclone", %{"remote_name" => "r2", "remote" => ":s3,secret_access_key=x:bucket"}},
            {"fake", %{"mode" => "ok", "remote" => "anything:"}}
          ] do
        assert {:error, error} =
                 Backups.create_backup_destination(%{name: "x", kind: kind, settings: settings},
                   actor: platform_admin()
                 )

        assert messages(error) =~ "remote is not a setting of this kind"
      end

      assert Backups.list_backup_destinations!(actor: platform_admin()) == []
    end

    test "a missing required field, and a setting of the wrong type" do
      assert {:error, error} =
               Backups.create_backup_destination(%{name: "x", kind: "fake", settings: %{}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "mode is required"

      assert {:error, error} =
               Backups.create_backup_destination(
                 %{name: "x", kind: "fake", settings: %{"mode" => 3}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "mode has the wrong type"
    end

    test "what the adapter's own validate/1 refuses" do
      assert {:error, error} =
               Backups.create_backup_destination(
                 %{name: "x", kind: "fake", settings: %{"mode" => "fail"}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "the store refused"
    end

    test "a ninth enabled destination; a disabled one is fine, until it is enabled" do
      admin = platform_admin()
      for _ <- 1..DestinationConfig.max_enabled(), do: destination!(%{}, admin)

      assert {:error, error} =
               Backups.create_backup_destination(
                 %{name: "Ninth", kind: "fake", settings: %{"mode" => "ok"}},
                 actor: admin
               )

      assert messages(error) =~ "at most 8 destinations can be enabled"

      ninth = destination!(%{enabled: false}, admin)

      assert {:error, error} =
               Backups.update_backup_destination(ninth, %{enabled: true}, actor: admin)

      assert messages(error) =~ "at most 8"

      [first | _] = Backups.list_enabled_backup_destinations!(actor: admin)
      {:ok, _} = Backups.update_backup_destination(first, %{enabled: false}, actor: admin)

      assert {:ok, %{enabled: true}} =
               Backups.update_backup_destination(ninth, %{enabled: true}, actor: admin)
    end

    test "a duplicate name" do
      admin = platform_admin()
      destination!(%{name: "Offsite"}, admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.create_backup_destination(
                 %{name: "Offsite", kind: "fake", settings: %{"mode" => "ok"}},
                 actor: admin
               )
    end
  end

  describe "where a destination writes (critic change 2)" do
    @tag :tmp_dir
    test "can't change after create; other edits still save", %{tmp_dir: tmp} do
      root = local_root(tmp)
      {:ok, d} = local(Path.join(root, "a"))

      assert {:error, error} =
               Backups.update_backup_destination(
                 d,
                 %{settings: %{"path" => Path.join(root, "b")}},
                 actor: platform_admin()
               )

      assert messages(error) =~ "add a new destination instead"

      # The same place, written differently, is not a move.
      assert {:ok, _} =
               Backups.update_backup_destination(
                 d,
                 %{settings: %{"path" => Path.join(root, "a") <> "/"}, name: "Renamed"},
                 actor: platform_admin()
               )
    end

    test "kind can't be changed at all" do
      d = destination!()

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.update_backup_destination(d, %{kind: "local"}, actor: platform_admin())
    end

    @tag :tmp_dir
    test "may not be, contain or sit inside the env remote", %{tmp_dir: tmp} do
      root = local_root(tmp)
      env = Path.join(root, "env")
      File.mkdir_p!(env)
      backups_env(:rclone_remote, env)

      for path <- [env, Path.join(env, "inside"), root] do
        assert {:error, error} = local(path)
        assert messages(error) =~ "another destination", "for #{path}"
      end

      assert {:ok, _} = local(Path.join(root, "envelope"))
    end

    @tag :tmp_dir
    test "may not be, contain or sit inside another destination", %{tmp_dir: tmp} do
      root = local_root(tmp)
      {:ok, _} = local(Path.join(root, "a/b"))

      for path <- [Path.join(root, "a/b"), Path.join(root, "a/b/c"), Path.join(root, "a")] do
        assert {:error, error} = local(path)
        assert messages(error) =~ "another destination", "for #{path}"
      end

      # Whole segments: a/bc is a place of its own.
      assert {:ok, _} = local(Path.join(root, "a/bc"))
    end
  end

  describe "an uninstalled adapter's destination" do
    setup do
      d =
        Ash.Seed.seed!(DestinationConfig, %{
          name: "Removed plugin",
          kind: "gone_plugin",
          settings: %{"bucket" => "b"}
        })

      %{d: d}
    end

    test "still reads, and can be renamed, disabled and deleted", %{d: d} do
      admin = platform_admin()
      assert [%{kind: "gone_plugin"}] = Backups.list_backup_destinations!(actor: admin)

      assert {:ok, d} =
               Backups.update_backup_destination(d, %{name: "Old", enabled: false}, actor: admin)

      # Enabling it again needs the adapter.
      assert {:error, error} =
               Backups.update_backup_destination(d, %{enabled: true}, actor: admin)

      assert messages(error) =~ "no installed backup destination"

      assert :ok = Backups.destroy_backup_destination(d, actor: admin)
    end

    test "is still a destination a backup tries, and fails as not installed", %{d: d} do
      assert {:ok, entries} = Destination.active()
      entry = Enum.find(entries, &(&1["id"] == d.id))
      assert entry["source"] == "db"
      assert Destination.resolve(entry) == {:error, :not_installed}
    end
  end

  describe "Destination.active/0 and resolve/1 with stored destinations" do
    test "lists the env destination first, then the enabled rows by position" do
      backups_env(:rclone_remote, "r2:kiln")
      admin = platform_admin()
      second = destination!(%{name: "Second", position: 2}, admin)
      first = destination!(%{name: "First", position: 1}, admin)
      _off = destination!(%{name: "Off", enabled: false}, admin)

      assert {:ok, [env, a, b]} = Destination.active()
      assert env["source"] == "env"

      assert a == %{
               "key" => "dest:" <> first.id,
               "id" => first.id,
               "kind" => "fake",
               "source" => "db",
               "label" => "First"
             }

      assert b["id"] == second.id
      refute inspect([env, a, b]) =~ @secret
    end

    test "fails closed when the destinations can't be read" do
      destination!()

      log =
        capture_log(fn ->
          assert Backups.with_actor(KilnCMS.SystemActor.new(:firing), &Destination.active/0) ==
                   {:error, :unreadable}
        end)

      assert log =~ "couldn't read the backup destinations"
    end

    test "a destination deleted or disabled since the backup started is :removed" do
      admin = platform_admin()
      d = destination!(%{}, admin)
      {:ok, [entry]} = Destination.active()

      {:ok, _} = Backups.update_backup_destination(d, %{enabled: false}, actor: admin)
      assert Destination.resolve(entry) == {:error, :removed}

      :ok =
        Backups.destroy_backup_destination(Backups.get_backup_destination!(d.id, actor: admin),
          actor: admin
        )

      assert Destination.resolve(entry) == {:error, :removed}
    end
  end

  describe "test_destination/2" do
    test "records the outcome, the node, and an audit event with the admin as actor" do
      admin = platform_admin()
      d = destination!(%{}, admin)

      assert {:ok, tested} = Backups.test_destination(d.id, actor: admin)
      assert tested.last_test_ok == true
      assert tested.last_test_error == nil
      assert tested.last_test_node == to_string(node())
      assert %DateTime{} = tested.last_tested_at

      assert [event] = events(:backup_destination_tested)
      assert event.actor_id == admin.id
      assert event.target_id == d.id

      assert event.metadata == %{
               "name" => d.name,
               "kind" => "fake",
               "ok" => true,
               "node" => to_string(node())
             }
    end

    test "a failing destination records a redacted error" do
      admin = platform_admin()
      d = destination!(%{settings: %{"mode" => "ok", "test_mode" => "fail"}}, admin)

      assert {:ok, tested} = Backups.test_destination(d.id, actor: admin)
      assert tested.last_test_ok == false
      assert tested.last_test_error =~ "the store refused ***"
      refute tested.last_test_error =~ @secret
    end

    test "a hanging destination fails at the bound" do
      admin = platform_admin()
      d = destination!(%{settings: %{"mode" => "ok", "test_mode" => "sleep"}}, admin)

      assert {:ok, tested} = Backups.test_destination(d.id, actor: admin, timeout: 50)
      assert tested.last_test_ok == false
      assert tested.last_test_error =~ "timed out"
    end

    test "an unknown id is :not_found" do
      assert Backups.test_destination(Ash.UUID.generate(), actor: platform_admin()) ==
               {:error, :not_found}
    end
  end

  describe "the audit log" do
    test "records create, change and delete with names, never settings values" do
      admin = platform_admin()
      d = destination!(%{name: "Nas"}, admin)

      assert [%{metadata: created}] = events(:backup_destination_created)

      assert created == %{
               "name" => "Nas",
               "kind" => "fake",
               "enabled" => true,
               "prune" => true,
               "secrets_changed" => true
             }

      {:ok, d} = Backups.update_backup_destination(d, %{prune: false, position: 3}, actor: admin)

      assert [%{metadata: %{"changed" => "position,prune", "prune" => false}}] =
               events(:backup_destination_changed)

      # Nothing changed: no event.
      {:ok, d} = Backups.update_backup_destination(d, %{prune: false}, actor: admin)
      assert length(events(:backup_destination_changed)) == 1

      :ok = Backups.destroy_backup_destination(d, actor: admin)

      assert [%{metadata: %{"name" => "Nas", "kind" => "fake", "enabled" => true}}] =
               events(:backup_destination_deleted)
    end
  end

  describe "discovery" do
    test "the vault walk finds the column" do
      assert {DestinationConfig, :secrets_encrypted} in Vault.encrypted_attributes()
    end
  end

  # #2952: a save from a stale record is refused; a Test is not an edit.
  describe "a stale save" do
    test "is refused, and the other save stands" do
      admin = platform_admin()
      opened = destination!(%{name: "Offsite"}, admin)

      {:ok, _} = Backups.update_backup_destination(opened, %{prune: false}, actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Backups.update_backup_destination(opened, %{name: "Renamed"}, actor: admin)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      assert %{name: "Offsite", prune: false} =
               Backups.get_backup_destination!(opened.id, actor: admin)

      assert [%{metadata: %{"changed" => "prune"}}] = events(:backup_destination_changed)
    end

    test "a Test leaves updated_at, so a record read before it still saves" do
      admin = platform_admin()
      opened = destination!(%{}, admin)

      assert {:ok, tested} = Backups.test_destination(opened.id, actor: admin)
      assert tested.updated_at == opened.updated_at
      assert %DateTime{} = tested.last_tested_at

      assert {:ok, %{name: "After the test"}} =
               Backups.update_backup_destination(opened, %{name: "After the test"}, actor: admin)
    end
  end

  # The cap under concurrency (#2952) is `DestinationCapRaceTest`: it needs
  # two real connections, which the sandbox doesn't give.

  # #2952: the env destination's Test, behind its read-only row's button.
  describe "test_env_destination/1" do
    @tag :tmp_dir
    test "runs the Rclone check on BACKUP_RCLONE_REMOTE and records nothing", %{tmp_dir: tmp} do
      path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", path) end)
      store = fake_rclone!(tmp)
      backups_env(:rclone_remote, "offsite:kiln/backups")

      assert {:ok, %{ok: true, error: nil, label: "offsite:kiln/backups"} = result} =
               Backups.test_env_destination(actor: platform_admin())

      assert result.node == to_string(node())
      assert %DateTime{} = result.at
      # The probe was written, read back and removed.
      assert File.ls!(store) == []
      assert events(:backup_destination_tested) == []
    end

    @tag :tmp_dir
    test "a failure is scrubbed of a connection-string remote's credentials", %{tmp_dir: tmp} do
      path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", path) end)
      fake_rclone!(tmp, fail?: true)

      backups_env(
        :rclone_remote,
        ":s3,access_key_id=AKIAENVTEST,secret_access_key=hunter2envtest:bucket"
      )

      assert {:ok, %{ok: false, error: error, label: label}} =
               Backups.test_env_destination(actor: platform_admin())

      assert error =~ "copyto refused"

      for secret <- ["AKIAENVTEST", "hunter2envtest"] do
        refute error =~ secret
        refute label =~ secret
      end
    end

    test "anyone but a platform admin is refused before anything runs" do
      backups_env(:rclone_remote, "offsite:kiln/backups")

      for actor <- [user(:editor), user(:viewer), site_admin(), nil] do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.test_env_destination(actor: actor)
      end
    end

    test "with BACKUP_RCLONE_REMOTE unset it is :not_set" do
      backups_env(:rclone_remote, nil)
      assert Backups.test_env_destination(actor: platform_admin()) == {:error, :not_set}
    end
  end
end
