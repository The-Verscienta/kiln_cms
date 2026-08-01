defmodule KilnCMS.CMS.ReadingTimeTest do
  @moduledoc """
  `reading_time_minutes` (#492): reading time derived from `word_count` at a
  configurable words-per-minute rate, exposed wherever `word_count` is.

  The point of computing it here is that every consumer was otherwise dividing
  by its own constant — so the arithmetic and the rate both need pinning.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Calculations.ReadingTime

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # `word_count` folds the block tree, so the words have to be real content.
  defp page_with_words(count) do
    body = Enum.map_join(1..max(count, 1), " ", &"word#{&1}")

    blocks =
      if count == 0, do: [], else: [%{type: :rich_text, content: "<p>#{body}</p>", order: 0}]

    CMS.create_page!(
      %{title: "Reading", slug: "rt-#{System.unique_integer([:positive])}", blocks: blocks},
      actor: admin()
    )
  end

  defp minutes(page) do
    page |> Ash.load!([:word_count, :reading_time_minutes], authorize?: false)
  end

  describe "reading_time_minutes" do
    test "is word_count divided by the rate, rounded up" do
      loaded = page_with_words(500) |> minutes()

      assert loaded.word_count == 500
      # 500 / 230 = 2.17 → 3, not 2: a partly-read third minute is still a
      # minute the reader spends.
      assert loaded.reading_time_minutes == 3
    end

    test "any content at all reads as at least a minute" do
      loaded = page_with_words(1) |> minutes()

      assert loaded.word_count == 1
      assert loaded.reading_time_minutes == 1
    end

    test "empty content reads as zero, not one" do
      loaded = page_with_words(0) |> minutes()

      assert loaded.word_count == 0
      assert loaded.reading_time_minutes == 0
    end

    test "an exact multiple of the rate does not round up a spurious minute" do
      loaded = page_with_words(ReadingTime.default_wpm()) |> minutes()

      assert loaded.reading_time_minutes == 1
    end
  end

  describe "the configured rate" do
    setup do
      previous = Application.get_env(:kiln_cms, :reading_time_wpm)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :reading_time_wpm)
          prev -> Application.put_env(:kiln_cms, :reading_time_wpm, prev)
        end
      end)

      :ok
    end

    test "defaults to 230 words per minute" do
      Application.delete_env(:kiln_cms, :reading_time_wpm)

      assert ReadingTime.words_per_minute() == 230
      assert ReadingTime.default_wpm() == 230
    end

    test "an override changes the answer" do
      page = page_with_words(500)
      assert minutes(page).reading_time_minutes == 3

      Application.put_env(:kiln_cms, :reading_time_wpm, 100)

      assert ReadingTime.words_per_minute() == 100
      assert minutes(page).reading_time_minutes == 5
    end

    # Fail to the default rather than interpreting the value: a `0` would divide
    # by zero and a negative would produce nonsense, and neither is a spelling of
    # an intent. Warned about so a typo is visible rather than silent.
    for bad <- [0, -5, "230", 230.0, nil] do
      test "#{inspect(bad)} is ignored in favour of the default" do
        Application.put_env(:kiln_cms, :reading_time_wpm, unquote(Macro.escape(bad)))

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert ReadingTime.words_per_minute() == ReadingTime.default_wpm()
          end)

        assert log =~ "reading_time_wpm"
      end
    end
  end

  describe "exposure" do
    # The whole reason the calculation exists rather than each consumer dividing
    # by its own constant — so it has to actually reach them.
    test "is public, so it reaches JSON:API and GraphQL like word_count" do
      calculation = Ash.Resource.Info.calculation(KilnCMS.CMS.Page, :reading_time_minutes)

      assert calculation.public?
      assert calculation.type == Ash.Type.Integer
    end

    test "is listed beside word_count on the admin show view" do
      admin_config = KilnCMS.CMS.Page |> AshAdmin.Resource.show_calculations()

      assert :reading_time_minutes in admin_config
      assert :word_count in admin_config
    end

    # Asserting `public?` only pins the DSL. Adding a `default_fields` list to
    # the json_api block would drop both fields from every response with the DSL
    # assertion still green, so load it the way a consumer's read does.
    test "loads on its own, without word_count being asked for" do
      page = page_with_words(500)
      loaded = Ash.load!(page, [:reading_time_minutes], authorize?: false)

      assert loaded.reading_time_minutes == 3
    end
  end

  describe "one counter, not several" do
    # The whole point of #492 is that consumers stop each computing their own
    # number. `BlockText` (the calculation) and `Kiln.Advisory.Body` (the
    # editor's advisory panel) split on whitespace with different regexes until
    # this change: `~r/\s+/` matches ASCII only, so a non-breaking space — what
    # `&nbsp;` decodes to, and what every Word/Google-Docs paste is full of —
    # did not separate words. The editor read one number and the API another.
    test "the API counter and the editor counter agree on non-breaking spaces" do
      text = "alpha\u00A0beta gamma\u00A0delta"
      blocks = [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]

      typed = KilnCMS.CMS.TypedBlocks.to_typed(blocks)

      assert KilnCMS.CMS.BlockText.word_count(blocks) == 4
      assert Kiln.Advisory.Body.from_typed(typed).word_count == 4
    end

    # The `reading_time` computed-field function used its own 200 wpm and
    # ignored the config, so a site with both surfaces got two answers.
    test "the computed-field function uses the configured rate" do
      previous = Application.get_env(:kiln_cms, :reading_time_wpm)
      on_exit(fn -> restore_wpm(previous) end)

      words = Enum.map_join(1..500, " ", &"word#{&1}")
      context = %{document: %{"body" => words}, fields: %{}}

      assert KilnCMS.CMS.Computed.evaluate("{{ reading_time(body) }}", context) == 3

      Application.put_env(:kiln_cms, :reading_time_wpm, 100)

      assert KilnCMS.CMS.Computed.evaluate("{{ reading_time(body) }}", context) == 5
    end
  end

  defp restore_wpm(nil), do: Application.delete_env(:kiln_cms, :reading_time_wpm)
  defp restore_wpm(prev), do: Application.put_env(:kiln_cms, :reading_time_wpm, prev)
end
