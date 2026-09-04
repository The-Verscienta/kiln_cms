defmodule KilnCMS.Analytics.ExportRecoveryTest do
  @moduledoc """
  #777's acceptance criterion, checked against an actual exported file: no
  suppressed referrer count is recoverable from the other values in the same
  export.

  `referrer_suppression_test.exs` already brute-forces
  `Analytics.suppress_referrer_group/1`. That is the algorithm; this is the
  **file**, and the two can disagree in ways only an end-to-end read catches:

    * the algorithm is handed a totals map, while the export builds one by
      grouping a stream — a breakdown split across batches would be decided
      twice, on two partial pictures
    * the algorithm assumes the reader knows the view total. The export prints
      that total on a *different row*, sourced from `ContentViewDay` rather than
      from the `ReferrerDay` rows the decision was made over. If those two ever
      disagree, the reader's arithmetic is not the arithmetic the algorithm
      protected against
    * the export's grain is per **day**, so totals are small and the residual is
      usually below the threshold — the regime where #1073 showed recovery is
      the common case rather than a corner

  The parser below reads only what a recipient of the file can read, and the
  search re-derives what they could deduce. Deliberately not calling
  `Analytics.ambiguous?/3`: that function is the claim under test, and a test
  that shares its arithmetic will agree with it about being wrong — which is how
  #620 shipped recoverable and stayed that way through #1054.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.ReferrerDay

  @password "password123456"
  @threshold 5

  setup do
    previous = Application.get_env(:kiln_cms, :analytics_referrers, [])

    Application.put_env(:kiln_cms, :analytics_referrers,
      enabled: true,
      low_count_threshold: @threshold
    )

    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, previous) end)
    :ok
  end

  defp admin do
    email = "aer-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  # `today/0` is KilnCMS.Test.StableDay's: ONE clock read per test, so every
  # seeded bucket and window bound in a test derives from the same day and a
  # run straddling UTC midnight can't disagree with itself (#1358).

  # One content item on one day: the exact view total the export prints, and the
  # referrer breakdown that sums to it. Every classified arrival writes one hit
  # alongside its view, so `views` is the sum — seeding it any other way would
  # test a population the export never produces.
  defp seed_day(breakdown) do
    id = Ash.UUID.generate()
    total = breakdown |> Map.values() |> Enum.sum()

    Ash.Seed.seed!(ContentViewDay, %{
      content_type: "page",
      content_id: id,
      day: today(),
      views: total
    })

    for {source, hits} <- breakdown, hits > 0 do
      Ash.Seed.seed!(ReferrerDay, %{
        content_type: "page",
        content_id: id,
        day: today(),
        source: source,
        hits: hits
      })
    end

    id
  end

  defp export(conn, id) do
    body =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin())
      |> get(
        ~p"/editor/analytics/export.csv?#{[from: Date.to_iso8601(today()), to: Date.to_iso8601(today())]}"
      )
      |> Map.fetch!(:resp_body)

    parse(body, id)
  end

  # What a recipient of the file sees for one content item: the exact view total
  # off the view row, and each referrer category's published cell.
  defp parse(body, id) do
    rows =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ","))
      |> Enum.filter(fn cells -> Enum.at(cells, 3) == id end)

    views =
      Enum.find_value(rows, fn
        ["view", _day, _type, _id, _title, views | _rest] -> String.to_integer(views)
        _other -> nil
      end)

    published =
      for ["referrer", _day, _type, _id, _title, _views, source, hits | _rest] <- rows,
          do: {source, hits}

    {views, published}
  end

  # Every assignment consistent with the file, from the recipient's side.
  #
  # They know the algorithm — it is documented, and Kiln is open source — so the
  # shape of the published row tells them which branch produced it, and the two
  # branches constrain a `"hidden"` cell very differently:
  #
  #   * **Partial** — some categories exact, one `"hidden"`. That one is the
  #     *partner*: the largest of the categories that were not naturally low, so
  #     it is `0` or at least the threshold, and at least every published exact.
  #     Modelling it as anything looser would make this test weaker than a real
  #     reader, which is the mistake #620 shipped.
  #   * **Whole breakdown** — every category `"hidden"`, the #1073 fallback. No
  #     partner was chosen, so nothing distinguishes these cells and each ranges
  #     over the entire residual. Applying the partner constraint here says the
  #     file is inconsistent with its own algorithm, which is a statement about
  #     the model rather than about recoverability.
  #
  # Lazy and truncated at two, because "more than one" is the entire question
  # and a `"hidden"` category otherwise ranges over the whole residual.
  defp consistent({views, published}) do
    exacts =
      for {_source, cell} <- published,
          {n, ""} <- [Integer.parse(cell)],
          do: n

    residual = views - Enum.sum(exacts)
    floor = Enum.max([@threshold | exacts])
    whole? = exacts == [] and Enum.all?(published, fn {_s, cell} -> cell == "hidden" end)

    ranges =
      for {source, cell} <- published, Integer.parse(cell) == :error do
        case cell do
          "hidden" when whole? -> {source, Enum.to_list(0..residual//1)}
          "hidden" -> {source, [0] ++ Enum.to_list(floor..max(floor, residual)//1)}
          "< " <> n -> {source, Enum.to_list(1..(String.to_integer(n) - 1)//1)}
        end
      end

    residual |> assignments(ranges) |> Enum.take(2)
  end

  defp assignments(0, []), do: [[]]
  defp assignments(_residual, []), do: []

  defp assignments(residual, [{source, values} | rest]) do
    values
    |> Stream.filter(&(&1 <= residual))
    |> Stream.flat_map(fn value ->
      residual |> Kernel.-(value) |> assignments(rest) |> Enum.map(&[{source, value} | &1])
    end)
  end

  # The four breakdowns #1073 brute-forced and found exactly recoverable under
  # the old algorithm. Every one of them reaches the export through the same
  # decision, so they are the cases that must survive a round trip through a
  # file — not just through the function.
  @cases [
    {"one low count and four genuine zeros", %{direct: 3}},
    {"one low count beside three large ones", %{direct: 2, search: 40, social: 50, other: 60}},
    {"one low count where every other category equals the threshold",
     %{direct: 4, search: 5, social: 5, other: 5}},
    {"two low counts and three genuine zeros", %{direct: 1, internal: 1}}
  ]

  for {name, breakdown} <- @cases do
    @breakdown breakdown

    test "#{name}: the export does not pin the suppressed value", %{conn: conn} do
      id = seed_day(@breakdown)
      {views, published} = file = export(conn, id)

      # The premise, asserted rather than assumed: the file really does print
      # the exact total beside the breakdown. Without this the test could pass
      # because the export omitted the view row, which is a different fix and
      # would make the search below vacuous.
      assert views == @breakdown |> Map.values() |> Enum.sum()
      assert length(published) == length(KilnCMS.Analytics.referrer_sources())

      # And something is actually hidden — otherwise there is nothing to recover
      # and every assertion below holds trivially.
      assert Enum.any?(published, fn {_source, cell} -> Integer.parse(cell) == :error end),
             "nothing was suppressed, so this case tests nothing: #{inspect(published)}"

      assert length(consistent(file)) >= 2,
             """
             the export pins a suppressed referrer count exactly.
             breakdown: #{inspect(@breakdown)}
             views: #{views}
             published: #{inspect(published)}
             """
    end
  end
end
