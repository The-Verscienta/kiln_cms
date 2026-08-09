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
      # The adapter names itself, which is one of the four things #731 asks for.
      assert html =~ "checkpoints are stored in the database only"
      refute html =~ "not been published to the witness"
    end

    test "counts an unpublished backlog even with the sink resolved to None", %{conn: conn} do
      # Gating the backlog on "is a witness configured?" rebuilds the hole this
      # issue closes: an unrecognised KILN_GOVERNANCE_WITNESS falls back to None
      # with a warning that only reaches stderr, so a typo would render a real
      # outage as a deliberate posture. The count is reported either way; only
      # the tone depends on whether anything refused.
      admin = authed_user(:admin)
      post = published_post(admin)
      use_adapter(Witness.None)

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)
      assert is_nil(checkpoint.witnessed_at)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "not been published to the witness"
    end

    test "reports the last checkpoint's sequence, coverage and publication time", %{conn: conn} do
      # Three of the four bullets the issue asks for, and none of them were
      # asserted by the states-only tests around this one.
      admin = authed_user(:admin)
      post = published_post(admin)
      use_file_sink()

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "Last checkpoint"
      assert html =~ "##{checkpoint.sequence}"
      assert html =~ "Covering"
      assert html =~ "#{checkpoint.document_count} document"
      assert html =~ "Published to the witness"
    end

    test "an empty panel when checkpointing is switched off", %{conn: conn} do
      prev = Application.get_env(:kiln_cms, :governance_checkpoints_enabled)
      Application.put_env(:kiln_cms, :governance_checkpoints_enabled, false)
      on_exit(fn -> restore_flag(prev) end)

      {:ok, _view, html} = live(log_in(conn, authed_user(:admin)), ~p"/editor/governance")

      assert html =~ "Checkpointing is switched off"
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

      assert html =~ "not been published to the witness"
      assert html =~ "witness_dir_not_configured"
      refute html =~ "Every checkpoint has been published"
    end

    test "reports a healthy witness once the checkpoint lands", %{conn: conn} do
      admin = authed_user(:admin)
      post = published_post(admin)
      use_file_sink()

      {:ok, checkpoint} = Checkpoint.mint(post.org_id)
      refute is_nil(checkpoint.witnessed_at)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance")

      assert html =~ "Every checkpoint has been published"
      refute html =~ "not been published to the witness"
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
      use_file_sink()

      # A checkpoint exists and covers an EARLIER document, so this exercises
      # the real `:none` branch — a document younger than the last checkpoint —
      # rather than the "no witness configured" short-circuit, which is what a
      # version of this test without the mint would have measured.
      covered = published_post(admin)
      {:ok, _checkpoint} = Checkpoint.mint(covered.org_id)

      later = published_post(admin)

      {:ok, _view, html} = live(log_in(conn, admin), ~p"/editor/governance/post/#{later.id}")

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

  defp restore_flag(nil), do: Application.delete_env(:kiln_cms, :governance_checkpoints_enabled)

  defp restore_flag(value),
    do: Application.put_env(:kiln_cms, :governance_checkpoints_enabled, value)

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
