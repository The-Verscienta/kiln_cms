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

  # Delegates to ExperimentFixtures.put_config/1 (#1120) — this used to be its
  # own copy of the get/put/on_exit-restore block, which didn't bust the
  # running-experiments cache on restore the way the shared fixture does.
  defp put_experiments(overrides), do: ExperimentFixtures.put_config(overrides)

  # Published: a draft document under test is a blocked reason of its own now,
  # so an unpublished fixture would render the strip for the wrong reason.
  defp page(actor, label) do
    %{title: label, slug: "ov-exp-#{System.unique_integer([:positive])}"}
    |> CMS.create_page!(actor: actor)
    |> CMS.publish_page!(%{}, actor: actor)
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

  describe "the deployment switch" do
    test "is stated once, not repeated under every experiment", %{conn: conn} do
      # It used to be a per-experiment reason, so a deployment with the default
      # (off) and three running experiments rendered a permanent strip with the
      # same sentence three times — and hid every real reason behind it.
      admin = authed_user(:admin)
      a = running_content_view_experiment(admin)
      b = running_content_view_experiment(admin)

      put_experiments(enabled: false)

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert html =~ "overview-experiment-warning"
      assert html =~ "Experiments are switched off for this deployment"

      # Once — not once per experiment, and no per-row reason invented for it.
      refute html =~ a.name
      refute html =~ b.name
      refute html =~ "not producing usable results"
    end

    test "does not hide a real reason underneath it", %{conn: conn} do
      admin = authed_user(:admin)
      experiment = running_content_view_experiment(admin)

      put_experiments(enabled: false, sticky: false)

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/overview")

      assert html =~ "Experiments are switched off for this deployment"
      assert html =~ experiment.name
      assert html =~ "sticky assignment is off"
    end

    test "an editor is shown neither half", %{conn: conn} do
      running_content_view_experiment(authed_user(:admin))
      put_experiments(enabled: false, sticky: false)

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/overview")

      refute html =~ "overview-experiment-warning"
    end
  end

  test "the headline does not claim 'cannot convert' for a goal that converts everything", %{
    conn: conn
  } do
    # `:funnel_ends_here` and `:goal_is_self` mean the experiment converts EVERY
    # impression, not none — the old headline said the opposite of its own
    # detail line.
    org_id = KilnCMS.Accounts.default_org_id()
    admin = authed_user(:admin)
    document = page(admin, "Doc")

    funnel =
      ExperimentFixtures.funnel_ending_at(page(admin, "First"), page(admin, "Last"), org_id)

    {_experiment, _c, _t} =
      ExperimentFixtures.running!(document, "page", %{},
        org_id: org_id,
        goal: :funnel_completion,
        goal_funnel_id: funnel.id
      )

    # `:start` refuses a funnel that already ends here, so the only way in is to
    # move the funnel afterwards — which needs no write to the experiment, and
    # is exactly why the state is reachable at all.
    KilnCMS.Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: document.id, position: 99},
      authorize?: false,
      tenant: org_id
    )

    KilnCMS.Cache.bust_funnel_targets(org_id)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/overview")

    assert html =~ "overview-experiment-warning"
    assert html =~ "not producing usable results"
    refute html =~ "cannot convert"
  end
end
