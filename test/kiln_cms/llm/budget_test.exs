defmodule KilnCMS.LLM.BudgetTest do
  @moduledoc """
  The shared LLM rate limiter, and the reserve that keeps an unattended caller
  off the units a person needs (#943).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.LLM.Budget

  defp org, do: "org-#{System.unique_integer([:positive])}"
  defp feature, do: "test-#{System.unique_integer([:positive])}"
  defp user, do: "user-#{System.unique_integer([:positive])}"

  @window :timer.hours(1)

  defp limits(overrides \\ []) do
    Keyword.merge([per_user: {1_000, @window}, per_org: {4, @window}], overrides)
  end

  defp unattended(overrides \\ []) do
    limits(Keyword.merge([unattended?: true, unattended_share: 0.5], overrides))
  end

  describe "unattended_ceiling/2" do
    test "is the floor of the share, so it never rounds UP into the reserve" do
      assert Budget.unattended_ceiling({200, @window}, 0.5) == 100
      assert Budget.unattended_ceiling({4, @window}, 0.5) == 2
      assert Budget.unattended_ceiling({5, @window}, 0.5) == 2
      assert Budget.unattended_ceiling({7, @window}, 0.75) == 5
    end

    test "float representation doesn't cost a unit" do
      # `90 * 0.7` is 62.99999999999999, and a bare floor hands back 62 where
      # both the docs and the operator expect 63.
      assert Budget.unattended_ceiling({90, @window}, 0.7) == 63
      assert Budget.unattended_ceiling({170, @window}, 0.7) == 119
    end

    test "the endpoints mean what they say" do
      assert Budget.unattended_ceiling({200, @window}, 0.0) == 0
      assert Budget.unattended_ceiling({200, @window}, 1.0) == 200
    end

    test "a ceiling that rounds to nothing IS nothing" do
      # A per-org limit of 1 has no share that leaves a unit for a human.
      assert Budget.unattended_ceiling({1, @window}, 0.5) == 0
    end

    test "a share that isn't a fraction fails closed and says so" do
      # `unattended_share: 50` — meaning percent — is the natural mistake, and
      # raising here would become an Oban retry storm in the one caller that
      # has retries.
      import ExUnit.CaptureLog

      for bad <- [50, 1.5, -0.1, "0.5", nil, :half] do
        log = capture_log(fn -> assert Budget.unattended_ceiling({200, @window}, bad) == 0 end)
        assert log =~ "unattended_share", "#{inspect(bad)} was not reported"
      end
    end

    test "an integer 0 or 1 is a number, and works" do
      assert Budget.unattended_ceiling({200, @window}, 1) == 200
      assert Budget.unattended_ceiling({200, @window}, 0) == 0
    end
  end

  describe "check/4 — the reserve" do
    test "an interactive caller never consults the ceiling" do
      feature = feature()
      org = org()
      editor = user()

      for _ <- 1..4, do: assert(:ok = Budget.check(feature, org, editor, limits()))
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, editor, limits())
    end

    test "an unattended caller stops at the share, leaving the rest for people" do
      feature = feature()
      org = org()

      assert :ok = Budget.check(feature, org, user(), unattended())
      assert :ok = Budget.check(feature, org, user(), unattended())
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, user(), unattended())

      assert :ok = Budget.check(feature, org, user(), limits())
      assert :ok = Budget.check(feature, org, user(), limits())
    end

    test "an unattended caller cannot take the LAST unit, however it was spent" do
      # THE property this issue is named for, and the one a sub-bucket counting
      # only unattended hits does not hold: automation has spent nothing, so
      # its own bucket would have room, but the org is one unit from empty and
      # that unit belongs to a person.
      feature = feature()
      org = org()

      for _ <- 1..3, do: assert(:ok = Budget.check(feature, org, user(), limits()))

      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, user(), unattended())
      assert :ok = Budget.check(feature, org, user(), limits())
    end

    test "the reserve tracks the shared counter, not a private one" do
      # One interactive call is enough to move automation's remaining room,
      # which is what distinguishes a reserve from a sub-ceiling.
      feature = feature()
      org = org()

      assert :ok = Budget.check(feature, org, user(), limits())
      assert :ok = Budget.check(feature, org, user(), unattended())
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, user(), unattended())
    end

    test "a refused unattended call does not spend an org unit on its way to being told no" do
      feature = feature()
      org = org()

      for _ <- 1..2, do: assert(:ok = Budget.check(feature, org, user(), unattended()))
      for _ <- 1..5, do: assert({:error, _} = Budget.check(feature, org, user(), unattended()))

      # The two the reserve held back are still there.
      assert :ok = Budget.check(feature, org, user(), limits())
      assert :ok = Budget.check(feature, org, user(), limits())
    end

    test "share 1.0 restores the old shared bucket, interleaved either way" do
      feature = feature()
      org = org()
      shared = unattended(unattended_share: 1.0)

      assert :ok = Budget.check(feature, org, user(), shared)
      assert :ok = Budget.check(feature, org, user(), limits())
      assert :ok = Budget.check(feature, org, user(), shared)
      assert :ok = Budget.check(feature, org, user(), limits())

      # Four is the org ceiling, and at 1.0 nothing was held back from either.
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, user(), shared)
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, user(), limits())
    end

    test "share 0.0 is a switch, and reports itself as one" do
      # Not `{:rate_limited, _}`: an operator told to retry in an hour will
      # wait out a window that never helps.
      feature = feature()
      org = org()

      assert {:error, :unattended_disabled} =
               Budget.check(feature, org, user(), unattended(unattended_share: 0.0))

      assert :ok = Budget.check(feature, org, user(), limits())
    end

    test "the share is required, not defaulted, when a caller says it is unattended" do
      # A feature that starts making unattended calls must choose its own
      # reserve rather than silently inherit one.
      assert_raise KeyError, fn ->
        Budget.check(feature(), org(), user(), limits(unattended?: true))
      end
    end

    test "buckets are namespaced by feature, so two features don't share a ceiling" do
      org = org()
      a = feature()
      b = feature()
      editor = user()

      for _ <- 1..4, do: assert(:ok = Budget.check(a, org, editor, limits()))
      assert {:error, _} = Budget.check(a, org, editor, limits())
      assert :ok = Budget.check(b, org, editor, limits())
    end

    test "a nil org skips the org buckets, reserve included — even at share 0.0" do
      # A mix task or a test has no tenant, and the module's contract is that a
      # limiter which can't identify a caller doesn't block one. The switch
      # must not quietly become an exception to that.
      feature = feature()

      for _ <- 1..10 do
        assert :ok = Budget.check(feature, nil, nil, unattended())
        assert :ok = Budget.check(feature, nil, nil, unattended(unattended_share: 0.0))
      end
    end

    test "the per-user bucket still applies to an unattended caller" do
      feature = feature()
      org = org()
      rule = user()
      tight = unattended(per_user: {1, @window})

      assert :ok = Budget.check(feature, org, rule, tight)
      assert {:error, {:rate_limited, _}} = Budget.check(feature, org, rule, tight)
    end
  end
end
