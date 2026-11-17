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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  # today/0: one memoized clock read per test — see KilnCMS.Test.StableDay (#1358).

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

  # Every breakdown consistent with the file, from the recipient's side.
  #
  # They know the algorithm — it is documented, and Kiln is open source — so the
  # shape of the published row tells them which branch produced it:
  #
  #   * **Partial** — some categories exact, one `"hidden"` partner. The reader
  #     tries every breakdown with the file's view total, the same exacts and
  #     each `"< n"` in its range, the partner taking what is left, and keeps
  #     the ones `Analytics.suppress_referrer_group/1` would have written into
  #     the file identically. Re-running the algorithm carries everything they
  #     know about the partner — the largest of the categories that are not
  #     naturally low, the first one on a tie — without restating it here. An
  #     earlier version let the partner be `0` or anything from the threshold
  #     up, a weaker reader than a real one, and it passed a file whose
  #     suppressed counts were pinned (#2752).
  #   * **Whole breakdown** — every category `"hidden"`, the #1073 fallback.
  #     Searched here only as a reader who does *not* know the algorithm, each
  #     cell over the whole residual. A reader who does can discard every
  #     breakdown the algorithm would have published partially, and for some
  #     small totals that leaves one; that is tracked separately (#2981), and
  #     these cases do not claim to cover it.
  #
  # Lazy and truncated at two, because "more than one" is the entire question.
  defp consistent({views, published}) do
    if Enum.all?(published, fn {_source, cell} -> cell == "hidden" end) do
      ranges = for {source, _cell} <- published, do: {source, 0..views//1}
      views |> assignments(ranges) |> Enum.take(2)
    else
      readings(views, published)
    end
  end

  defp readings(views, published) do
    exact = for {source, cell} <- published, {n, ""} <- [Integer.parse(cell)], do: {source, n}
    lows = for {source, "< " <> n} <- published, do: {source, 1..(String.to_integer(n) - 1)//1}
    # No partner when every suppressed category is naturally low: the lows
    # then carry the whole residual on their own.
    partner = for {source, "hidden"} <- published, do: {source, 0..views//1}
    residual = views - (exact |> Enum.map(&elem(&1, 1)) |> Enum.sum())
    file = Map.new(published)

    residual
    |> assignments(partner ++ lows)
    |> Stream.map(&Map.new(exact ++ &1))
    |> Stream.filter(&(as_written(&1) == file))
    |> Enum.take(2)
  end

  # The cells `suppress_referrer_group/1` would have written for a candidate.
  defp as_written(candidate) do
    candidate
    |> Map.new(fn {source, hits} -> {String.to_existing_atom(source), hits} end)
    |> KilnCMS.Analytics.suppress_referrer_group()
    |> Map.new(fn {source, _hits, display} -> {to_string(source), to_string(display)} end)
  end

  defp assignments(0, []), do: [[]]
  defp assignments(_residual, []), do: []

  defp assignments(residual, [{source, values} | rest]) do
    values
    |> Stream.filter(&(&1 <= residual))
    |> Stream.flat_map(fn value ->
      residual |> Kernel.-(value) |> assignments(rest) |> Stream.map(&[{source, value} | &1])
    end)
  end

  # The four breakdowns #1073 brute-forced and found exactly recoverable under
  # the old algorithm, and the shapes #2752 found the same way. Every one of
  # them reaches the export through the same decision, so they are the cases
  # that must survive a round trip through a file — not just through the
  # function.
  @cases [
    {"one low count and four genuine zeros", %{direct: 3}},
    {"one low count beside three large ones", %{direct: 2, search: 40, social: 50, other: 60}},
    {"one low count where every other category equals the threshold",
     %{direct: 4, search: 5, social: 5, other: 5}},
    {"two low counts and three genuine zeros", %{direct: 1, internal: 1}},
    # #2752: a published 5 bounds the partner below by 5, which the earlier
    # search did not know, so it accepted a file that pinned both low counts.
    {"two low counts beside two at the threshold", %{direct: 1, search: 1, social: 5, other: 5}},
    # The zeros ahead of `social` would have won a tie at 0, so the partner is
    # not 0 either — which the issue's one-line fix still missed.
    {"two low counts with zeros ahead of the partner", %{search: 1, social: 5, other: 1}},
    # Every category naturally low: published partially with no `"hidden"`
    # partner at all, so the reader has only the lows to split the residual.
    {"every category naturally low", %{direct: 1, internal: 1, search: 1, social: 1, other: 2}}
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
