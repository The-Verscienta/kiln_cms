defmodule KilnCMSWeb.GovernanceWitnessPanelTest do
  @moduledoc """
  The governance dashboard's witness status panel (#731).

  `async: false`, for the reason `KilnCMS.GovernanceWitnessTest` is: the witness
  adapter is global application config, so a test that swaps it would otherwise
  decide what a concurrently running test in another file sees.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.Witness

  @password "password123456"

  setup do
    prev = Application.get_env(:kiln_cms, Witness)
    prev_file = Application.get_env(:kiln_cms, Witness.File)

    on_exit(fn ->
      restore(Witness, prev)
      restore(Witness.File, prev_file)
    end)

    :ok
  end

  describe "the index panel" do
    test "says so when no witness is configured, rather than looking healthy", %{conn: conn} do
      # The default posture. It must read as a deliberate choice, not a fault —
      # rendering it as an alarm is how an operator learns to ignore the panel.
      use_adapter(Witness.None)

      {:ok, _view, html} = live(log_in(conn, authed_user(:admin)), ~p"/editor/governance")

      assert html =~ "History witness"
      assert html =~ "No external witness is configured"
      refute html =~ "have not been accepted by the witness"
    end

    test "surfaces a failed publication and dates it", %{conn: conn} do
      # The whole point of #731: `witness_error` was written on every failed
      # publication and shown nowhere, so a deployment silently unwitnessed for
      # weeks looked exactly like a healthy one here.
      admin = authed_user(:admin)
      post = published_post(admin)

      # A configured adapter with nowhere to write: the checkpoint is minted and
      # the publication fails, which is exactly the state that was invisible.
      use_adapter(Witness.File)
      Application.put_env(:kiln_cms, Witness.File, [])

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)
      assert is_nil(checkpoint.witnessed_at)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "have not been accepted by the witness"
      assert html =~ "witness_dir_not_configured"
      refute html =~ "Every checkpoint has been accepted"
    end

    test "reports a healthy witness once the checkpoint lands", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_post(admin)
      use_file_sink()

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)
      refute is_nil(checkpoint.witnessed_at)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "Every checkpoint has been accepted"
      refute html =~ "have not been accepted by the witness"
    end
  end

  describe "the per-document badge" do
    test "names the checkpoint witnessing that document, and its anchor position", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_post(admin)
      use_file_sink()

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      assert html =~ "Witnessed by checkpoint ##{checkpoint.sequence}"
      assert html =~ "anchor position"
    end

    test "a document no checkpoint covers gets no badge at all", %{conn: conn} do
      # Younger than the last checkpoint is the ordinary case, not a fault, and
      # so is every document on a deployment with no sink. A badge on each would
      # be noise that teaches an operator to stop reading badges.
      admin = authed_user(:admin)
      post = published_post(admin)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{post.id}")

      refute html =~ "Witnessed by checkpoint"
      refute html =~ "witness-position"
    end
  end

  defp use_adapter(module), do: Application.put_env(:kiln_cms, Witness, adapter: module)

  defp use_file_sink do
    dir = Path.join(System.tmp_dir!(), "kiln-witness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    use_adapter(Witness.File)
    Application.put_env(:kiln_cms, Witness.File, dir: dir)
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp published_post(admin) do
    post =
      CMS.create_post!(
        %{title: "Witnessed #{System.unique_integer([:positive])}", slug: slug()},
        actor: admin
      )

    CMS.publish_post!(post, %{}, actor: admin)
  end

  defp slug, do: "govw-#{System.unique_integer([:positive])}"

  defp authed_user(role) do
    email = "govw-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
