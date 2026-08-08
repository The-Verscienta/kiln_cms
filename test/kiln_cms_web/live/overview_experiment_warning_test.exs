defmodule KilnCMSWeb.OverviewExperimentWarningTest do
  @moduledoc """
  The overview's "this experiment cannot convert" strip (#1008).

  Its own file, and `async: false`, because every case here turns the
  deployment-wide `KilnCMS.Experiments` config on and off. `OverviewLiveTest` is
  `async: true`, and application env is global — a sticky flag flipped there
  would reach whatever else happened to be running, which is precisely the class
  of flake that is impossible to reproduce afterwards.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures

  @password "password123456"

  defp authed_user(role) do
    email = "ov-exp-#{System.unique_integer([:positive])}@example.com"

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

  defp put_experiments(overrides) do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)
  end

  defp page(actor, label) do
    CMS.create_page!(
      %{title: label, slug: "ov-exp-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  # A later-page goal, because sticky is the premise that goes away underneath a
  # running experiment without anyone touching it — the case the strip exists for.
  defp running_content_view_experiment(actor) do
    org_id = KilnCMS.Accounts.default_org_id()

    {experiment, _control, _treatment} =
      ExperimentFixtures.running!(page(actor, "Doc"), "page", %{},
        org_id: org_id,
        goal: :content_view,
        goal_content_type: "page",
        goal_document_id: page(actor, "Goal").id
      )

    experiment
  end

  setup do
    ExperimentFixtures.enable!()
    put_experiments(sticky: true)
    :ok
  end

  test "is absent when every running experiment can convert", %{conn: conn} do
    # A permanent banner is one nobody reads; its absence is what makes the
    # present one land. Same reasoning as the backup strip beside it.
    admin = authed_user(:admin)
    running_content_view_experiment(admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/overview")

    refute html =~ "overview-experiment-warning"
  end

  test "names the experiment and why, once it cannot", %{conn: conn} do
    admin = authed_user(:admin)
    experiment = running_content_view_experiment(admin)

    put_experiments(sticky: false)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/overview")

    assert html =~ "overview-experiment-warning"
    assert html =~ experiment.name
    assert html =~ "sticky assignment is off"
  end

  test "an editor is never shown it", %{conn: conn} do
    # The fixes are a config flag or a deleted goal document — neither is an
    # editor's to make, and telling them would be a dead end.
    running_content_view_experiment(authed_user(:admin))
    put_experiments(sticky: false)

    {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

    refute html =~ "overview-experiment-warning"
  end

  test "a site with no experiments renders nothing extra", %{conn: conn} do
    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/overview")

    refute html =~ "overview-experiment-warning"
  end
end
