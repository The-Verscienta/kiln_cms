defmodule KilnCMSWeb.BackupDestinationsLiveTest do
  @moduledoc """
  The Destinations tab (`/editor/backups/destinations`, #2220): who may use
  it, the forms generated from an adapter's fields, that a secret never
  reaches the page, Test, reorder, enable and delete, and that every write
  is audited.

  `async: false`: the backup config (directory, the Local roots,
  `BACKUP_RCLONE_REMOTE`) is VM-wide `Application` env.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  import KilnCMS.Test.BackupSchedules, only: [user: 1, site_admin: 0, platform_admin: 0]
  import KilnCMS.Test.BackupDestinations, only: [destination!: 3, fake_rclone!: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Backups
  alias KilnCMSWeb.BackupDestinationsLive

  @path "/editor/backups/destinations"
  @secret "s3cr3t-dest-token-9f2c"

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

    root = Path.join(tmp, "root")
    File.mkdir_p!(root)

    put_backups(
      enabled: true,
      dir: Path.join(tmp, "backups"),
      media_dir: nil,
      rclone_remote: nil,
      local_destination_roots: []
    )

    %{root: root}
  end

  defp put_backups(opts) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups, []), opts)
    )
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(signed_in(user))
  end

  # Signed in through the password strategy, as `BackupScheduleLiveTest`
  # does, so the session carries a real token.
  defp signed_in(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(user.email), "password" => "password123456"},
        []
      )

    user
  end

  defp mount(conn, user \\ platform_admin(), locale \\ nil) do
    conn = log_in(conn, user)
    conn = if locale, do: Plug.Conn.put_session(conn, "locale", locale), else: conn
    {:ok, lv, _html} = live(conn, @path)
    lv
  end

  defp stored(id), do: Backups.get_backup_destination!(id, actor: Backups.system())

  defp all_destinations,
    do: Backups.list_backup_destinations!(actor: Backups.system()) |> Enum.sort_by(& &1.position)

  defp events(type) do
    KilnCMS.Security.list_instance_events!(actor: platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  # A Fake destination with the secret `@secret`.
  defp fake!(attrs \\ %{}), do: destination!(attrs, platform_admin(), @secret)

  describe "who can use it" do
    test "anonymous is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, @path)
    end

    test "an editor and a viewer are turned away", %{conn: conn} do
      for role <- [:editor, :viewer] do
        assert {:error, {:redirect, _}} = conn |> log_in(user(role)) |> live(@path)
      end
    end

    # The route's gate is a per-org admin tier; a destination receives the
    # whole instance's backups.
    test "an org admin who is not a platform admin is turned away by the page itself",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
               conn |> log_in(site_admin()) |> live(@path)
    end

    test "a platform admin gets the tab, marked current", %{conn: conn} do
      lv = mount(conn)

      assert has_element?(lv, "#backup-tab-destinations[aria-current=page]", "Destinations")
      assert has_element?(lv, "#backup-tab-history[href='/editor/backups']")
      assert has_element?(lv, "#backup-tab-schedule[href='/editor/backups/schedules']")
      assert has_element?(lv, "#backup-destinations-empty")
    end
  end

  # Called directly: a refused mount leaves no socket to push events down, so
  # the question is what each handler does on its own with a socket whose
  # user is not (or no longer) a platform admin. Nothing is written, tested
  # or read first.
  describe "each handler refuses a socket that isn't a platform admin's" do
    setup do
      row = fake!()

      expired = %{
        role: :editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      sockets =
        for user <- [%{role: :editor}, expired, site_admin()] do
          %Phoenix.LiveView.Socket{
            assigns: %{
              __changed__: %{},
              flash: %{},
              current_user: user,
              testing: MapSet.new(),
              picking?: true,
              editing: :new,
              kind: "fake",
              fields: [],
              destinations: [row]
            }
          }
        end

      %{row: row, sockets: sockets}
    end

    defp assert_denied({:noreply, socket}) do
      assert {:live, :redirect, %{to: "/access-denied?needs=platform"}} = socket.redirected
      assert socket.assigns.flash == %{}
    end

    test "every event is refused, and nothing changes", %{row: row, sockets: sockets} do
      params = %{
        "id" => row.id,
        "kind" => "fake",
        "dir" => "down",
        "destination" => %{
          "name" => "Forged",
          "enabled" => "false",
          "settings" => %{"mode" => "ok"},
          "secrets" => %{"token" => "forged"}
        }
      }

      for socket <- sockets,
          event <- ~w(new pick edit cancel validate save toggle delete move test test_env) do
        assert_denied(BackupDestinationsLive.handle_event(event, params, socket))
      end

      assert [%{id: id, name: name, enabled: true}] = all_destinations()
      assert id == row.id
      assert name == row.name
      assert events(:backup_destination_tested) == []
    end

    test "a Test's result is not applied for someone no longer a platform admin", %{
      row: row,
      sockets: sockets
    } do
      for socket <- sockets do
        assert_denied(
          BackupDestinationsLive.handle_async({:test, row.id}, {:ok, {:ok, row}}, socket)
        )

        assert_denied(
          BackupDestinationsLive.handle_async({:test, row.id}, {:exit, :boom}, socket)
        )
      end
    end

    test "handle_params sends them away", %{sockets: sockets} do
      for socket <- sockets do
        assert_denied(BackupDestinationsLive.handle_params(%{}, @path, socket))
      end
    end

    test "a connected page whose admin lost the role is sent away on the next click", %{
      conn: conn,
      row: row
    } do
      admin = platform_admin()

      for event <- ~w(toggle test test_env edit delete move) do
        lv = mount(conn, admin)

        :sys.replace_state(lv.pid, fn state ->
          update_in(
            state.socket,
            &Phoenix.Component.assign(&1, :current_user, %{admin | role: :editor})
          )
        end)

        assert {:error, {:live_redirect, %{to: "/access-denied?needs=platform"}}} =
                 render_click(lv, event, %{"id" => row.id, "dir" => "down"})
      end

      assert stored(row.id).enabled
      assert is_nil(stored(row.id).last_tested_at)
    end
  end

  describe "adding a destination" do
    test "picks a kind, generates the form from its fields, saves it and audits it", %{
      conn: conn
    } do
      lv = mount(conn)

      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-fake") |> render_click()

      # The adapter's fields, humanized; the secret a password box with no value.
      assert has_element?(lv, "#destination-new-mode[name='destination[settings][mode]']")
      assert has_element?(lv, "label[for=destination-new-test_mode]", "Test mode")

      assert has_element?(
               lv,
               "input#destination-new-token[type=password][name='destination[secrets][token]'][value='']"
             )

      html =
        lv
        |> form("#destination-form",
          destination: %{
            name: "Offsite NAS",
            settings: %{mode: "ok"},
            secrets: %{token: @secret}
          }
        )
        |> render_submit()

      refute html =~ @secret
      assert html =~ "Destination added."

      assert [
               %{name: "Offsite NAS", kind: "fake", enabled: true, settings: %{"mode" => "ok"}} =
                 row
             ] =
               all_destinations()

      assert {:ok, %{"token" => @secret}} =
               KilnCMS.Backups.DestinationConfig.decrypt_secrets(row.secrets_encrypted)

      assert [%{target_id: target}] = events(:backup_destination_created)
      assert target == row.id
      assert has_element?(lv, "#backup-destination-#{row.id}", "Offsite NAS")
    end

    test "a refused save shows the error under the field and never the secret", %{conn: conn} do
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-fake") |> render_click()

      # `mode` is required.
      html =
        lv
        |> form("#destination-form",
          destination: %{name: "No mode", secrets: %{token: @secret}}
        )
        |> render_submit()

      refute html =~ @secret
      assert has_element?(lv, "#destination-form", "mode is required")
      assert all_destinations() == []

      # The adapter's own `validate/1` refuses, naming the secret: scrubbed.
      html =
        lv
        |> form("#destination-form",
          destination: %{name: "Failing", settings: %{mode: "fail"}, secrets: %{token: @secret}}
        )
        |> render_submit()

      refute html =~ @secret
      assert has_element?(lv, "#destination-form-errors", "the store refused")
      assert all_destinations() == []
    end

    test "a submitted kind is never read: the picked one is saved", %{conn: conn} do
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-fake") |> render_click()

      render_submit(lv, "save", %{
        "destination" => %{"name" => "Picked", "kind" => "local", "settings" => %{"mode" => "ok"}}
      })

      assert [%{kind: "fake"}] = all_destinations()
    end

    test "Local is offered only when BACKUP_LOCAL_DESTINATION_ROOTS lists somewhere", %{
      conn: conn,
      root: root
    } do
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()

      refute has_element?(lv, "#destination-kind-local")
      assert has_element?(lv, "#destination-local-hint", "BACKUP_LOCAL_DESTINATION_ROOTS")
      assert has_element?(lv, "#destination-kind-rclone")

      # A forged pick of it is ignored.
      render_click(lv, "pick", %{"kind" => "local"})
      refute has_element?(lv, "#destination-form")

      put_backups(local_destination_roots: [root])
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()

      assert has_element?(lv, "#destination-kind-local", "Directory on this server")
      refute has_element?(lv, "#destination-local-hint")
    end
  end

  describe "an S3 destination (#2221)" do
    @key_id "AKIDS3FORMTEST"
    @s3_secret "s3-form-secret-access-key"

    test "both keys are write-only, the lifecycle hint is shown, and the row says where", %{
      conn: conn
    } do
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-s3") |> render_click()

      for name <- ["access_key_id", "secret_access_key"] do
        assert has_element?(
                 lv,
                 "input#destination-new-#{name}[type=password][name='destination[secrets][#{name}]'][value='']"
               )
      end

      assert has_element?(lv, "#destination-s3-hint", "lifecycle rule")

      # #3084: S3 uploads resume, said once; the lifecycle rule stays in its
      # own hint.
      assert has_element?(lv, "#destination-resume-hint", "Uploads resume after an interruption.")

      # #3087: "Access key ID", not humanize's "Access key"; Path style says
      # when a private host needs it.
      assert has_element?(lv, "label[for=destination-new-access_key_id]", "Access key ID")
      assert has_element?(lv, "label[for=destination-new-secret_access_key]", "Secret access key")

      assert has_element?(
               lv,
               "#destination-new-path_style-hint",
               "Required for a private host unless <bucket>.<host> is listed in BACKUP_S3_PRIVATE_HOSTS."
             )

      html =
        lv
        |> form("#destination-form",
          destination: %{
            name: "Bucket",
            settings: %{
              endpoint: "https://s3.test",
              region: "auto",
              bucket: "kiln-backups",
              prefix: "/site/",
              path_style: "true"
            },
            secrets: %{access_key_id: @key_id, secret_access_key: @s3_secret}
          }
        )
        |> render_submit()

      assert html =~ "Destination added."
      refute html =~ @key_id
      refute html =~ @s3_secret

      assert [%{kind: "s3", settings: %{"path_style" => true}} = row] = all_destinations()
      refute Map.has_key?(row.settings, "access_key_id")

      assert {:ok, %{"access_key_id" => @key_id, "secret_access_key" => @s3_secret}} =
               KilnCMS.Backups.DestinationConfig.decrypt_secrets(row.secrets_encrypted)

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=location]",
               "s3://kiln-backups/site (s3.test)"
             )

      # Editing: where it writes is fixed, and neither key comes back.
      html = lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()
      refute html =~ @key_id
      refute html =~ @s3_secret

      for name <- ["endpoint", "bucket", "prefix"] do
        assert has_element?(lv, "input#destination-#{row.id}-#{name}[readonly][data-locked=true]")
      end

      refute has_element?(lv, "input#destination-#{row.id}-region[readonly]")
    end

    test "an endpoint over http:// is refused unless its host is listed", %{conn: conn} do
      lv = mount(conn)
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-s3") |> render_click()

      lv
      |> form("#destination-form",
        destination: %{
          name: "LAN",
          settings: %{endpoint: "http://minio.lan:9000", region: "us-east-1", bucket: "kiln"},
          secrets: %{access_key_id: @key_id, secret_access_key: @s3_secret}
        }
      )
      |> render_submit()

      assert has_element?(lv, "#destination-form-panel", "BACKUP_S3_PRIVATE_HOSTS")
      assert all_destinations() == []
    end
  end

  describe "editing" do
    test "the secret is never filled in; blank keeps it; the change is audited", %{conn: conn} do
      row = fake!()
      lv = mount(conn)

      html = lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()

      refute html =~ @secret
      assert has_element?(lv, "input#destination-#{row.id}-token[type=password][value='']")
      assert has_element?(lv, "#destination-form", "Leave blank to keep the stored value.")

      html =
        lv
        |> form("#destination-form",
          destination: %{name: "Renamed", secrets: %{token: ""}}
        )
        |> render_submit()

      refute html =~ @secret
      assert html =~ "Destination saved."

      assert %{name: "Renamed"} = updated = stored(row.id)

      assert {:ok, %{"token" => @secret}} =
               KilnCMS.Backups.DestinationConfig.decrypt_secrets(updated.secrets_encrypted)

      assert [%{metadata: %{"changed" => "name"}}] = events(:backup_destination_changed)
    end

    test "where a destination writes is read-only, and a forged change is not saved", %{
      conn: conn,
      root: root
    } do
      put_backups(local_destination_roots: [root])
      path = Path.join(root, "nas")

      row =
        Backups.create_backup_destination!(
          %{name: "NAS", kind: "local", settings: %{"path" => path}},
          actor: platform_admin()
        )

      lv = mount(conn)
      lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()

      assert has_element?(
               lv,
               "input#destination-#{row.id}-path[readonly][data-locked=true][value='#{path}']"
             )

      render_submit(lv, "save", %{
        "destination" => %{
          "name" => "NAS 2",
          "enabled" => "true",
          "prune" => "true",
          "settings" => %{"path" => Path.join(root, "elsewhere")}
        }
      })

      assert %{name: "NAS 2", settings: %{"path" => ^path}} = stored(row.id)
    end
  end

  describe "the list" do
    test "the env destination is read-only, with where it comes from", %{conn: conn} do
      put_backups(rclone_remote: "offsite:kiln/backups")
      lv = mount(conn)

      assert has_element?(lv, "#backup-destination-env", "offsite:kiln/backups")

      assert has_element?(
               lv,
               "#backup-destination-env [data-role=source]",
               "From BACKUP_RCLONE_REMOTE — change it in the server's environment"
             )

      # Read-only: a Test (#2952), nothing that changes it.
      assert has_element?(lv, "#backup-destination-env button[data-role=test]", "Test")

      for role <- ~w(edit toggle up down delete) do
        refute has_element?(lv, "#backup-destination-env [data-role=#{role}]")
      end

      refute has_element?(lv, "#backup-destinations-empty")
    end

    test "a connection-string env remote's credentials never reach the page", %{conn: conn} do
      put_backups(rclone_remote: ":s3,access_key_id=AKIAEXAMPLE,secret_access_key=hunter2:bucket")
      {:ok, _lv, html} = conn |> log_in(platform_admin()) |> live(@path)

      refute html =~ "hunter2"
      refute html =~ "AKIAEXAMPLE"
    end

    test "disable and enable: flashed, persisted and audited", %{conn: conn} do
      row = fake!()
      lv = mount(conn)

      assert lv |> element("#backup-destination-#{row.id} [data-role=toggle]") |> render_click() =~
               "Destination disabled."

      refute stored(row.id).enabled
      assert has_element?(lv, "#backup-destination-#{row.id} [data-role=disabled]")

      assert lv |> element("#backup-destination-#{row.id} [data-role=toggle]") |> render_click() =~
               "Destination enabled."

      assert stored(row.id).enabled

      assert [_, _] = changed = events(:backup_destination_changed)
      assert Enum.all?(changed, &(&1.metadata["changed"] == "enabled"))
    end

    test "delete asks first, then deletes and audits", %{conn: conn} do
      row = fake!()
      lv = mount(conn)

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=delete][data-confirm*='#{row.name}']"
             )

      assert lv |> element("#backup-destination-#{row.id} [data-role=delete]") |> render_click() =~
               "Destination deleted."

      assert all_destinations() == []
      assert [%{target_id: target}] = events(:backup_destination_deleted)
      assert target == row.id
    end

    test "reorder moves a destination and records each position written", %{conn: conn} do
      a = fake!(%{name: "A"})
      b = fake!(%{name: "B"})
      lv = mount(conn)

      # Both start at position 0, by creation: A first.
      refute has_element?(lv, "#backup-destination-#{a.id} [data-role=up]")
      lv |> element("#backup-destination-#{a.id} [data-role=down]") |> render_click()

      assert ["B", "A"] = Enum.map(all_destinations(), & &1.name)
      assert has_element?(lv, "#backup-destination-#{a.id} [data-role=up]")
      refute has_element?(lv, "#backup-destination-#{a.id} [data-role=down]")

      # B moved to 0 is no change; A to 1 is.
      assert [%{target_id: target, metadata: %{"changed" => "position"}}] =
               events(:backup_destination_changed)

      assert target == a.id
      assert b.position == 0
    end

    test "a destination deleted in another tab is a flash, not a crash", %{conn: conn} do
      row = fake!()
      lv = mount(conn)
      Backups.destroy_backup_destination!(row, actor: platform_admin())

      assert lv |> element("#backup-destination-#{row.id} [data-role=toggle]") |> render_click() =~
               "That destination no longer exists."

      refute has_element?(lv, "#backup-destination-#{row.id}")
    end
  end

  describe "Test" do
    test "a passing test says so, with the node, on the row and in a flash", %{conn: conn} do
      row = fake!()
      lv = mount(conn)

      lv |> element("#backup-destination-#{row.id} [data-role=test]") |> render_click()
      html = render_async(lv, 2_000)

      assert html =~ "the test passed"

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=last-test]",
               "Last test passed"
             )

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=last-test]",
               to_string(node())
             )

      assert [_] = events(:backup_destination_tested)
    end

    test "a failing test shows the error, redacted of the secret", %{conn: conn} do
      row = fake!(%{settings: %{"mode" => "ok", "test_mode" => "fail"}})
      lv = mount(conn)

      lv |> element("#backup-destination-#{row.id} [data-role=test]") |> render_click()
      html = render_async(lv, 2_000)

      refute html =~ @secret
      assert html =~ "the test failed"

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=last-test]",
               "the store refused"
             )

      refute stored(row.id).last_test_ok
    end

    test "one test at a time per destination: a second click while it runs does nothing", %{
      conn: conn
    } do
      row = fake!(%{settings: %{"mode" => "ok", "test_mode" => "sleep", "sleep_ms" => 300}})
      lv = mount(conn)

      lv |> element("#backup-destination-#{row.id} [data-role=test]") |> render_click()

      assert has_element?(
               lv,
               "#backup-destination-#{row.id} [data-role=test][disabled]",
               "Testing…"
             )

      # A forged second click (the button is disabled) starts nothing.
      render_click(lv, "test", %{"id" => row.id})

      render_async(lv, 2_000)
      assert [_] = events(:backup_destination_tested)
      refute has_element?(lv, "#backup-destination-#{row.id} [data-role=test][disabled]")
    end
  end

  # #3084: only a kind whose uploads resume says so.
  test "a kind that can't resume has no resume hint", %{conn: conn} do
    lv = mount(conn)
    lv |> element("#destination-new") |> render_click()
    lv |> element("#destination-kind-rclone") |> render_click()

    assert has_element?(lv, "#destination-form")
    refute has_element?(lv, "#destination-resume-hint")
    refute has_element?(lv, "#destination-s3-hint")
  end

  # #2952: Kiln's own adapters' labels are translated; a plugin's stay as
  # it names its fields.
  describe "field labels" do
    test "Kiln's own adapters' labels are translated", %{conn: conn} do
      lv = mount(conn, platform_admin(), "fr")
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-s3") |> render_click()

      for {name, label} <- [
            {"endpoint", "Point de terminaison"},
            {"region", "Région"},
            {"bucket", "Bucket"},
            {"prefix", "Préfixe"},
            {"path_style", "Adressage par chemin"},
            {"access_key_id", "ID de clé d’accès"},
            {"secret_access_key", "Clé d’accès secrète"}
          ] do
        assert has_element?(lv, "label[for=destination-new-#{name}]", label)
      end

      assert has_element?(lv, "#destination-resume-hint", "Les téléversements reprennent")
      assert has_element?(lv, "#destination-new-path_style-hint", "BACKUP_S3_PRIVATE_HOSTS")
      lv |> element("#destination-form-panel button", "Annuler") |> render_click()

      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-rclone") |> render_click()
      assert has_element?(lv, "label[for=destination-new-remote_name]", "Nom du remote")
      assert has_element?(lv, "label[for=destination-new-path]", "Chemin")
    end

    test "a plugin's fields are its names, humanized, in every locale", %{conn: conn} do
      lv = mount(conn, platform_admin(), "fr")
      lv |> element("#destination-new") |> render_click()
      lv |> element("#destination-kind-fake") |> render_click()

      assert has_element?(lv, "label[for=destination-new-mode]", "Mode")
      assert has_element?(lv, "label[for=destination-new-token]", "Token")
    end
  end

  # #2952: a form opened before another save doesn't write over it.
  describe "a stale form" do
    test "a Save after another change is refused, says so, and saves nothing", %{conn: conn} do
      row = fake!(%{name: "Offsite"})
      lv = mount(conn)
      lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()

      # Another tab disables it meanwhile.
      Backups.update_backup_destination!(row, %{enabled: false}, actor: platform_admin())

      lv
      |> form("#destination-form", destination: %{name: "Renamed", enabled: "true"})
      |> render_submit()

      assert has_element?(
               lv,
               "#destination-form-errors",
               "This destination was changed since you opened it, so nothing was saved."
             )

      assert %{name: "Offsite", enabled: false} = stored(row.id)
      assert [%{metadata: %{"changed" => "enabled"}}] = events(:backup_destination_changed)

      # Opened again, it saves.
      lv |> element("#destination-form-panel button", "Cancel") |> render_click()
      lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()

      assert lv
             |> form("#destination-form", destination: %{name: "Renamed"})
             |> render_submit() =~ "Destination saved."

      assert %{name: "Renamed", enabled: false} = stored(row.id)
    end

    test "a Test while the form is open doesn't make it stale", %{conn: conn} do
      row = fake!()
      lv = mount(conn)
      lv |> element("#backup-destination-#{row.id} [data-role=edit]") |> render_click()
      lv |> element("#backup-destination-#{row.id} [data-role=test]") |> render_click()
      render_async(lv, 2_000)

      assert lv
             |> form("#destination-form", destination: %{name: "After the test"})
             |> render_submit() =~ "Destination saved."

      assert %{name: "After the test"} = stored(row.id)
    end
  end

  # #2952: the env destination's Test, as a stored Rclone one's, never
  # showing the remote's credentials.
  describe "Test on the env destination" do
    setup %{tmp_dir: tmp} do
      path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", path) end)
      %{tmp: tmp}
    end

    test "a passing test says so on the row and in a flash, and records nothing", %{
      conn: conn,
      tmp: tmp
    } do
      fake_rclone!(tmp, [])
      put_backups(rclone_remote: "offsite:kiln/backups")
      lv = mount(conn)

      lv |> element("#backup-destination-env [data-role=test]") |> render_click()
      html = render_async(lv, 2_000)

      assert html =~ "offsite:kiln/backups: the test passed"

      assert has_element?(
               lv,
               "#backup-destination-env [data-role=last-test]",
               "Last test passed"
             )

      refute has_element?(lv, "#backup-destination-env [data-role=test][disabled]")
      assert events(:backup_destination_tested) == []
    end

    test "a failing test shows the error, without the remote's credentials", %{
      conn: conn,
      tmp: tmp
    } do
      fake_rclone!(tmp, fail?: true)

      put_backups(
        rclone_remote: ":s3,access_key_id=AKIAENVFORM,secret_access_key=hunter2envform:bucket"
      )

      lv = mount(conn)
      lv |> element("#backup-destination-env [data-role=test]") |> render_click()
      html = render_async(lv, 2_000)

      assert html =~ "the test failed"
      assert has_element?(lv, "#backup-destination-env [data-role=last-test]", "copyto refused")
      refute html =~ "AKIAENVFORM"
      refute html =~ "hunter2envform"
    end
  end
end
