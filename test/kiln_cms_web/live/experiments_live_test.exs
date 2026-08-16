defmodule KilnCMSWeb.ExperimentsLiveTest do
  @moduledoc """
  `/editor/experiments` and `/editor/experiments/:id` (#982): the admin auth
  matrix, creating against a picked document, authoring a variant against the
  block tree (diffed to a sparse patch), the lifecycle, the results panel with
  its floor and its blocked reason (#1087), and promotion.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  @password "password1234!"

  defp authed_user(role) do
    email = "explive-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp post!(actor) do
    CMS.create_post!(
      %{
        title: "Original title",
        excerpt: "Original excerpt",
        slug: "explive-#{System.unique_integer([:positive])}",
        locale: "en",
        blocks: [%{"_type" => "heading", "text" => "Hello", "level" => 2}]
      },
      actor: actor
    )
    |> CMS.publish_post!(%{}, actor: actor)
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/experiments")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/experiments")

      assert flash["error"] =~ "admin access"
    end

    test "loads for an admin, with the switch-off notice when experiments are off", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/experiments")
      assert html =~ "Experiments"
      assert html =~ "switched off on this deployment"
    end
  end

  describe "creating" do
    test "creates a draft with a control against the picked document and goal form", %{conn: conn} do
      admin = authed_user(:admin)
      post = post!(admin)
      form = ExperimentFixtures.goal_form!(org_id())

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/experiments")

      # Pick the type first, so the document select fills for it.
      render_change(lv, "pick_type", %{"experiment" => %{"content_type" => "post"}})
      assert has_element?(lv, ~s(option[value="#{post.id}"]))

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#new-experiment",
          experiment: %{
            name: "Headline test",
            content_type: "post",
            document_id: post.id,
            goal: "form_submission",
            goal_form_id: form.id
          }
        )
        |> render_submit()

      assert to =~ ~r{/editor/experiments/[0-9a-f-]+}

      [experiment] =
        Experiments.list_experiments!(
          query: [load: :variants],
          authorize?: false,
          tenant: org_id()
        )
        |> Enum.filter(&(&1.name == "Headline test"))

      assert experiment.state == :draft
      assert experiment.content_type == "post"
      assert experiment.document_id == post.id
      assert experiment.goal_form_id == form.id
      assert [%{control: true, patch: %{}}] = experiment.variants
    end
  end

  describe "the experiment page" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      post = post!(admin)
      form = ExperimentFixtures.goal_form!(org_id())

      experiment =
        Experiments.create_experiment!(
          %{name: "Page test", content_type: "post", document_id: post.id, goal_form_id: form.id},
          actor: admin,
          tenant: org_id()
        )

      ExperimentFixtures.variant!(experiment, "Control", %{}, org_id(), control: true)
      conn = log_in(conn, admin)
      %{admin: admin, post: post, experiment: experiment, conn: conn}
    end

    test "authors a variant against the block tree and saves only what changed", %{
      conn: conn,
      experiment: experiment,
      post: post
    } do
      {:ok, lv, _html} = live(conn, ~p"/editor/experiments/#{experiment.id}")

      lv |> element("button", "Add variant") |> render_click()

      # The form is prefilled from the document — title, excerpt, and the
      # heading block's text field.
      post = CMS.get_post!(post.id, authorize?: false)
      [heading] = Enum.map(post.blocks, &KilnCMS.CMS.TypedBlocks.input_map/1)
      assert has_element?(lv, ~s(#field-title[value="Original title"]))
      assert has_element?(lv, ~s(#field-excerpt[value="Original excerpt"]))
      assert has_element?(lv, ~s(#block-#{heading["id"]}-text[value="Hello"]))

      lv
      |> form("#variant-form",
        variant: %{
          name: "B",
          weight: "2",
          fields: %{"title" => "Punchier title", "excerpt" => "Original excerpt"},
          blocks: %{heading["id"] => %{"text" => "Hello there"}}
        }
      )
      |> render_submit()

      variants =
        Experiments.list_variants!(
          authorize?: false,
          tenant: org_id(),
          query: [filter: [experiment_id: experiment.id]]
        )

      b = Enum.find(variants, &(&1.name == "B"))
      assert b.weight == 2
      # Sparse: the unchanged excerpt is not in the patch.
      assert b.patch == %{
               "fields" => %{"title" => "Punchier title"},
               "blocks" => %{heading["id"] => %{"text" => "Hello there"}}
             }
    end

    test "start → results with the floor notice, blocked reason above the counters, conclude, promote",
         %{
           conn: conn,
           experiment: experiment,
           post: post,
           admin: admin
         } do
      ExperimentFixtures.put_config(results_floor: 2)

      treatment =
        ExperimentFixtures.variant!(
          experiment,
          "B",
          %{"fields" => %{"title" => "Winning title"}},
          org_id(),
          []
        )

      {:ok, lv, _html} = live(conn, ~p"/editor/experiments/#{experiment.id}")
      html = lv |> element("button", "Start") |> render_click()
      assert html =~ "Experiment started."
      # Variants are locked while running.
      assert html =~ "variants are locked"
      refute has_element?(lv, "button", "Add variant")

      # No counters yet: the floor notice, no leader.
      assert has_element?(lv, "#results-floor")
      refute render(lv) =~ "leading"

      # Enough impressions on both arms; B converts better.
      for _ <- 1..3,
          do: Experiments.record_impression!(treatment.id, authorize?: false, tenant: org_id())

      Experiments.record_conversion!(treatment.id, authorize?: false, tenant: org_id())

      [control] =
        Enum.reject(
          Experiments.list_variants!(
            authorize?: false,
            tenant: org_id(),
            query: [filter: [experiment_id: experiment.id]]
          ),
          &(&1.id == treatment.id)
        )

      for _ <- 1..3,
          do: Experiments.record_impression!(control.id, authorize?: false, tenant: org_id())

      # Re-render via a no-op event path: reload the page.
      {:ok, lv, html} = live(conn, ~p"/editor/experiments/#{experiment.id}")
      assert html =~ "leading"
      assert has_element?(lv, "#result-#{treatment.id} .badge", "leading")
      refute has_element?(lv, "#results-floor")

      # #1087: a blocked experiment says so above the counters. Delete the goal
      # form out from under it.
      CMS.destroy_form!(CMS.get_form!(experiment.goal_form_id, authorize?: false),
        authorize?: false
      )

      {:ok, lv, html} = live(conn, ~p"/editor/experiments/#{experiment.id}")
      assert has_element?(lv, "#results-blocked")
      assert html =~ "its goal form has been deleted"
      # …and the leader is not called out under a blocked banner? It still
      # renders (the counters are subordinated, not hidden) but the banner
      # comes first in the DOM.
      {blocked_at, _} = :binary.match(html, "results-blocked")
      {table_at, _} = :binary.match(html, "results-table")
      assert blocked_at < table_at

      # Conclude with B as the winner, then promote.
      html =
        lv
        |> form("form[phx-submit=conclude]", %{"winner_variant_id" => treatment.id})
        |> render_submit()

      assert html =~ "Experiment concluded"
      assert has_element?(lv, "button", "Promote winner into document")

      html = lv |> element("button", "Promote winner into document") |> render_click()
      assert html =~ "Winner promoted"
      assert CMS.get_post!(post.id, actor: admin).title == "Winning title"
    end

    test "delete removes a draft and returns to the list", %{conn: conn, experiment: experiment} do
      {:ok, lv, _html} = live(conn, ~p"/editor/experiments/#{experiment.id}")

      assert {:error, {:live_redirect, %{to: "/editor/experiments"}}} =
               lv |> element("button", "Delete") |> render_click()

      assert {:error, _} =
               Experiments.get_experiment(experiment.id, authorize?: false, tenant: org_id())
    end

    test "an unknown id redirects to the list with a message", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/editor/experiments", flash: flash}}} =
               live(conn, ~p"/editor/experiments/#{Ash.UUID.generate()}")

      assert flash["error"] =~ "doesn't exist"
    end
  end

  describe "the shared phrases (#1087)" do
    test "every Health reason atom the overview knows is phrased, and the set is total" do
      alias KilnCMSWeb.ExperimentPhrases

      for reason <- [
            :sticky_off,
            :no_goal_form,
            :goal_form_missing,
            :no_target,
            :no_goal_funnel,
            :goal_is_self,
            :goal_type_unknown,
            :goal_document_missing,
            :funnel_ends_here,
            :funnel_target_missing,
            :document_missing,
            :document_unpublished,
            :goal_document_unpublished,
            :goal_form_inactive,
            :goal_unreadable,
            :unknown_goal
          ] do
        assert is_binary(ExperimentPhrases.blocked_headline(reason))
      end

      # Total: an atom added to Health without a phrase must not crash a page.
      assert ExperimentPhrases.blocked_headline(:something_new) =~ "can no longer be reached"

      assert ExperimentPhrases.anomaly_headline(:conversions_exceed_impressions) =~
               "more conversions"

      assert is_binary(ExperimentPhrases.anomaly_headline(:novel))
    end
  end
end
