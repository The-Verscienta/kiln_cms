defmodule KilnCMS.Experiments.ResultsAndPromotionTest do
  @moduledoc """
  The two domain pieces the editor UI stands on (#982): what the results panel
  may say (`Results` — the sample-size floor, the leader rule, blocked and
  anomalous states surfaced alongside), and promotion of a winner into the
  document through the ordinary `:update` (`Promotion`).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.{Promotion, Results}

  setup do
    org_id = KilnCMS.Accounts.default_org_id()
    %{org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # A post rather than a page: `excerpt` is patchable and posts have one.
  # Published, because `Health` reports an unpublished document under test as
  # blocked (nothing is served, so no arm can be shown).
  defp page!(actor, blocks \\ []) do
    CMS.create_post!(
      %{
        title: "Original title",
        excerpt: "Original excerpt",
        slug: "rp-#{System.unique_integer([:positive])}",
        locale: "en",
        blocks: blocks
      },
      actor: actor
    )
    |> CMS.publish_post!(%{}, actor: actor)
  end

  defp record!(variant_id, org_id, impressions, conversions) do
    for _ <- 1..impressions//1,
        do: Experiments.record_impression!(variant_id, authorize?: false, tenant: org_id)

    for _ <- 1..conversions//1,
        do: Experiments.record_conversion!(variant_id, authorize?: false, tenant: org_id)
  end

  defp loaded(experiment, org_id),
    do:
      Experiments.get_experiment!(experiment.id,
        load: [:variants],
        authorize?: false,
        tenant: org_id
      )

  describe "Results.summarize/2" do
    test "totals per variant, control first, with rates", %{org_id: org_id, actor: actor} do
      page = page!(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      record!(control.id, org_id, 4, 1)
      record!(treatment.id, org_id, 5, 2)

      summary = Results.summarize(loaded(experiment, org_id), org_id)

      assert [
               %{variant: %{id: c}, impressions: 4, conversions: 1, rate: 0.25},
               %{variant: %{id: t}, impressions: 5, conversions: 2, rate: 0.4}
             ] =
               summary.rows

      assert c == control.id and t == treatment.id
      assert summary.total_impressions == 9
      assert summary.total_conversions == 3
      assert summary.blocked == nil
    end

    test "below the floor no leader is called, however lopsided the rates", %{
      org_id: org_id,
      actor: actor
    } do
      ExperimentFixtures.put_config(results_floor: 10)
      page = page!(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      record!(control.id, org_id, 9, 0)
      record!(treatment.id, org_id, 50, 40)

      summary = Results.summarize(loaded(experiment, org_id), org_id)
      assert summary.floor == 10
      refute summary.decidable?
      assert summary.leader == nil
    end

    test "at the floor on every arm the strictly-highest rate leads; a tie leads nobody", %{
      org_id: org_id,
      actor: actor
    } do
      ExperimentFixtures.put_config(results_floor: 10)
      page = page!(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      record!(control.id, org_id, 10, 1)
      record!(treatment.id, org_id, 10, 3)

      summary = Results.summarize(loaded(experiment, org_id), org_id)
      assert summary.decidable?
      assert summary.leader.id == treatment.id

      # Tie: two more conversions on the control.
      record!(control.id, org_id, 0, 2)
      assert Results.summarize(loaded(experiment, org_id), org_id).leader == nil
    end

    test "an anomalous arm (conversions > impressions) is flagged and never leads", %{
      org_id: org_id,
      actor: actor
    } do
      ExperimentFixtures.put_config(results_floor: 1)
      page = page!(actor)

      {experiment, control, treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      record!(control.id, org_id, 5, 1)
      record!(treatment.id, org_id, 1, 3)

      summary = Results.summarize(loaded(experiment, org_id), org_id)
      [_control_row, treatment_row] = summary.rows
      assert {:conversions_exceed_impressions, _} = treatment_row.anomaly
      assert summary.leader.id == control.id
    end

    test "a blocked experiment is reported so the panel cannot show a bare rate", %{
      org_id: org_id,
      actor: actor
    } do
      page = page!(actor)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      # Delete the goal form out from under it.
      CMS.destroy_form!(CMS.get_form!(experiment.goal_form_id, authorize?: false),
        authorize?: false
      )

      summary = Results.summarize(loaded(experiment, org_id), org_id)
      assert {:goal_form_missing, _sentence} = summary.blocked
    end

    test "the floor is configurable and defaults to 100" do
      ExperimentFixtures.put_config(results_floor: nil)
      assert Results.floor() == 100
      ExperimentFixtures.put_config(results_floor: 25)
      assert Results.floor() == 25
    end
  end

  describe "Promotion.promote/2" do
    defp concluded!(page, patch, org_id) do
      {experiment, _control, treatment} = ExperimentFixtures.running!(page, "post", patch)

      {:ok, concluded} =
        Experiments.conclude_experiment(experiment, treatment.id,
          authorize?: false,
          tenant: org_id
        )

      {loaded(concluded, org_id), treatment}
    end

    test "writes the winning fields into the document through the ordinary update, as the actor",
         %{
           org_id: org_id,
           actor: actor
         } do
      page = page!(actor)

      {experiment, _treatment} =
        concluded!(page, %{"fields" => %{"title" => "Winning title"}}, org_id)

      assert {:ok, updated} = Promotion.promote(experiment, actor: actor, tenant: org_id)
      assert updated.title == "Winning title"
      # Only what the patch named changed.
      assert updated.excerpt == "Original excerpt"

      # A normal version was cut, as any human edit would.
      assert CMS.get_post!(page.id, actor: actor).title == "Winning title"
    end

    test "writes a block patch by the block's stable id, leaving the rest of the tree alone", %{
      org_id: org_id,
      actor: actor
    } do
      page =
        page!(actor, [
          %{"_type" => "heading", "text" => "First", "level" => 2},
          %{"_type" => "heading", "text" => "Second", "level" => 2}
        ])

      page = CMS.get_post!(page.id, actor: actor)
      [first, second] = Enum.map(page.blocks, &KilnCMS.CMS.TypedBlocks.input_map/1)

      {experiment, _treatment} =
        concluded!(page, %{"blocks" => %{second["id"] => %{"text" => "Second, winning"}}}, org_id)

      assert {:ok, updated} = Promotion.promote(experiment, actor: actor, tenant: org_id)
      [first_after, second_after] = Enum.map(updated.blocks, &KilnCMS.CMS.TypedBlocks.input_map/1)
      assert first_after["text"] == "First"
      assert first_after["id"] == first["id"]
      assert second_after["text"] == "Second, winning"
      assert second_after["id"] == second["id"]
    end

    test "refuses: not concluded, no winner, the control winning", %{org_id: org_id, actor: actor} do
      page = page!(actor)

      {running, control, _treatment} =
        ExperimentFixtures.running!(page, "post", %{"fields" => %{"title" => "B"}})

      assert {:error, :not_concluded} =
               Promotion.promote(loaded(running, org_id), actor: actor, tenant: org_id)

      {:ok, no_winner} =
        Experiments.conclude_experiment(running, nil, authorize?: false, tenant: org_id)

      assert {:error, :no_winner} =
               Promotion.promote(loaded(no_winner, org_id), actor: actor, tenant: org_id)

      page2 = page!(actor)

      {running2, control2, _} =
        ExperimentFixtures.running!(page2, "post", %{"fields" => %{"title" => "B"}})

      {:ok, control_won} =
        Experiments.conclude_experiment(running2, control2.id, authorize?: false, tenant: org_id)

      assert {:error, :winner_is_control} =
               Promotion.promote(loaded(control_won, org_id), actor: actor, tenant: org_id)

      _ = control
    end

    test "is authorized as the actor: a viewer cannot promote", %{org_id: org_id, actor: actor} do
      page = page!(actor)

      {experiment, _treatment} =
        concluded!(page, %{"fields" => %{"title" => "Winning title"}}, org_id)

      viewer =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "rpv-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        })

      assert {:error, _} = Promotion.promote(experiment, actor: viewer, tenant: org_id)
      assert CMS.get_post!(page.id, actor: actor).title == "Original title"
    end
  end
end
