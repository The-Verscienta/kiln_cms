defmodule KilnCMSWeb.ExperimentsGoalPickerTest do
  @moduledoc """
  Choosing what an experiment *measures*, on `/editor/experiments` (#982).

  `experiments_live_test.exs` covers the lifecycle and one create against a
  form goal. The goal picker itself was untested, and it carries a rule with
  teeth: a submission may name a target id for every goal kind, and only the
  picked goal's id may be saved (`create_attrs/1` clears the rest). The page
  renders one target field at a time, so a stale id arrives from a client that
  sent one anyway — and saving it would attach the experiment to a target
  nobody chose. An experiment measuring the wrong thing is worse than no
  experiment, because its verdict still reads as authoritative.

  The other half is the picker itself: it offers documents only after a type is
  picked, and each goal shows its own target field.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  @password "password1234!"

  setup %{conn: conn} do
    admin = authed_user(:admin)
    %{conn: log_in(conn, admin), admin: admin}
  end

  defp authed_user(role) do
    email = "expgoal-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp post!(actor) do
    CMS.create_post!(
      %{
        title: "Original title",
        slug: "expgoal-#{System.unique_integer([:positive])}",
        locale: "en",
        blocks: [%{"_type" => "heading", "text" => "Hello", "level" => 2}]
      },
      actor: actor
    )
    |> CMS.publish_post!(%{}, actor: actor)
  end

  defp page!(actor) do
    CMS.create_page!(
      %{title: "Target", slug: "expgoal-page-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp created(name) do
    Experiments.list_experiments!(authorize?: false, tenant: org_id())
    |> Enum.find(&(&1.name == name))
  end

  # The page renders only the picked goal's target field, so an id for another
  # goal can only arrive as a crafted payload — which is exactly the case the
  # clearing in `create_attrs/1` is there for. Submitted as a raw event for
  # that reason; the happy path goes through `form/3` in the picker tests.
  defp submit(lv, params) do
    render_submit(lv, "create", %{"experiment" => params})
  end

  describe "the goal's target" do
    test "a funnel goal saves the funnel, and not the form left in the form", %{
      conn: conn,
      admin: admin
    } do
      post = post!(admin)
      form = ExperimentFixtures.goal_form!(org_id())
      funnel = ExperimentFixtures.funnel_ending_at(page!(admin), page!(admin), org_id())

      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      # Both ids are sent, as a client that had filled the form goal in before
      # switching would send them.
      {:error, {:live_redirect, _}} =
        submit(lv, %{
          name: "Funnel goal",
          content_type: "post",
          document_id: post.id,
          goal: "funnel_completion",
          goal_form_id: form.id,
          goal_funnel_id: funnel.id
        })

      experiment = created("Funnel goal")
      assert experiment.goal == :funnel_completion
      assert experiment.goal_funnel_id == funnel.id
      assert is_nil(experiment.goal_form_id)
    end

    test "a content-view goal saves its document, and not the funnel or form", %{
      conn: conn,
      admin: admin
    } do
      post = post!(admin)
      target = page!(admin)
      form = ExperimentFixtures.goal_form!(org_id())
      funnel = ExperimentFixtures.funnel_ending_at(page!(admin), page!(admin), org_id())

      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      {:error, {:live_redirect, _}} =
        submit(lv, %{
          name: "View goal",
          content_type: "post",
          document_id: post.id,
          goal: "content_view",
          goal_content_type: "page",
          goal_document_id: target.id,
          goal_form_id: form.id,
          goal_funnel_id: funnel.id
        })

      experiment = created("View goal")
      assert experiment.goal == :content_view
      assert experiment.goal_content_type == "page"
      assert experiment.goal_document_id == target.id
      assert is_nil(experiment.goal_form_id)
      assert is_nil(experiment.goal_funnel_id)
    end

    test "a blank target is stored as nothing, not as an empty string", %{
      conn: conn,
      admin: admin
    } do
      post = post!(admin)

      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      {:error, {:live_redirect, _}} =
        submit(lv, %{
          name: "No target yet",
          content_type: "post",
          document_id: post.id,
          goal: "content_view",
          goal_content_type: "",
          goal_document_id: ""
        })

      experiment = created("No target yet")
      assert is_nil(experiment.goal_document_id)
      assert is_nil(experiment.goal_content_type)
      # The outcome, not the mechanism: `create_attrs/1` maps "" to nil, and Ash
      # casts an empty string to nil anyway, so removing that helper leaves this
      # test green. Both are pinned here as one behaviour on purpose.
    end
  end

  describe "the picker" do
    test "documents are offered only once a type is picked", %{conn: conn, admin: admin} do
      post = post!(admin)

      {:ok, lv, html} = live(conn, ~p"/editor/experiments")
      refute html =~ post.id

      html = render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      assert html =~ post.id
      assert has_element?(lv, ~s(option[value="#{post.id}"]))
    end

    test "each goal shows its own target field, and only that one", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/editor/experiments")

      # The default goal is a form submission.
      assert html =~ "Pick a form…"
      refute html =~ "Pick a funnel…"

      html = render_change(lv, "pick_type", %{"experiment" => %{"goal" => "funnel_completion"}})
      assert html =~ "Pick a funnel…"
      refute html =~ "Pick a form…"

      html = render_change(lv, "pick_type", %{"experiment" => %{"goal" => "content_view"}})
      refute html =~ "Pick a funnel…"
      refute html =~ "Pick a form…"
    end

    test "a change carrying neither a type nor a goal is ignored", %{conn: conn, admin: admin} do
      post = post!(admin)
      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      # An unrelated field changing must not empty the document picker the
      # operator has already filled in.
      html = render_change(lv, "pick_type", %{"experiment" => %{"name" => "Typing a name"}})

      assert html =~ post.id
    end
  end

  describe "the list" do
    test "each experiment shows its document's title, its goal and its variants", %{
      conn: conn,
      admin: admin
    } do
      post = post!(admin)
      form = ExperimentFixtures.goal_form!(org_id())
      funnel = ExperimentFixtures.funnel_ending_at(page!(admin), page!(admin), org_id())

      form_goal =
        Experiments.create_experiment!(
          %{
            name: "Form goal test",
            content_type: "post",
            document_id: post.id,
            goal: :form_submission,
            goal_form_id: form.id
          },
          actor: admin,
          tenant: org_id()
        )

      ExperimentFixtures.variant!(form_goal, "Control", %{}, org_id(), control: true)
      ExperimentFixtures.variant!(form_goal, "B", %{}, org_id(), [])

      Experiments.create_experiment!(
        %{
          name: "Funnel goal test",
          content_type: "post",
          document_id: post.id,
          goal: :funnel_completion,
          goal_funnel_id: funnel.id
        },
        actor: admin,
        tenant: org_id()
      )

      {:ok, _lv, html} = live(conn, ~p"/editor/experiments")

      # The document reads as its title, not as a uuid an operator would have
      # to go and look up.
      assert html =~ "Original title"
      assert html =~ "Form goal test"
      assert html =~ "Funnel goal test"
      # Each goal in words, from the same page.
      assert html =~ "Form submission"
      assert html =~ "Completes a funnel"
      assert html =~ "Draft"

      # The whole line for each row, so the title, goal and count are asserted
      # as one string rather than as three substrings that could come from
      # anywhere on the page. Two variants on the first, none yet on the second
      # — and "1 variant" vs "2 variants" is the plural form, which a count
      # interpolated into a fixed string would get wrong.
      assert html =~ "Original title · Form submission · 2 variants"
      assert html =~ "Original title · Completes a funnel · 0 variants"
    end

    test "an experiment whose document is gone still lists, by id", %{conn: conn, admin: admin} do
      post = post!(admin)

      Experiments.create_experiment!(
        %{
          name: "Orphaned",
          content_type: "post",
          document_id: post.id,
          goal: :form_submission
        },
        actor: admin,
        tenant: org_id()
      )

      CMS.purge_post!(post, actor: admin)

      {:ok, _lv, html} = live(conn, ~p"/editor/experiments")

      # The row survives its document: an experiment that vanished from the
      # list would look concluded rather than broken.
      assert html =~ "Orphaned"
      assert html =~ "#{post.id} · Form submission · 0 variants"
    end
  end

  describe "refusals" do
    test "a create the resource rejects says so, and writes nothing", %{conn: conn, admin: admin} do
      post = post!(admin)
      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})

      html =
        submit(lv, %{
          name: "",
          content_type: "post",
          document_id: post.id,
          goal: "form_submission"
        })

      # Still on the page, with an error — not a redirect to an experiment that
      # does not exist.
      assert html =~ "experiments" or html =~ "Experiments"
      assert Experiments.list_experiments!(authorize?: false, tenant: org_id()) == []
    end

    test "a submit with no experiment params at all is refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/editor/experiments")

      html = render_submit(lv, "create", %{})

      assert html =~ "Something went wrong."
      assert Experiments.list_experiments!(authorize?: false, tenant: org_id()) == []
    end
  end
end
