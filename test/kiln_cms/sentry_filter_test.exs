defmodule KilnCMS.SentryFilterTest do
  @moduledoc """
  The `before_send` hook drops expected transient mail-retry noise and leaves
  every other event untouched.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Mail.TransientDeliveryError
  alias KilnCMS.SentryFilter

  # Sentry.Event enforces :event_id/:timestamp; the values are irrelevant here.
  defp event(fields),
    do: struct!(Sentry.Event, Keyword.merge([event_id: "id", timestamp: "now"], fields))

  test "drops transient mail-delivery failures" do
    event =
      event(
        original_exception: %TransientDeliveryError{message: "transient delivery failure: ..."}
      )

    assert SentryFilter.before_send(event) == nil
  end

  test "passes every other event through unchanged" do
    runtime = event(original_exception: %RuntimeError{message: "boom"})
    assert SentryFilter.before_send(runtime) == runtime

    no_exception = event(original_exception: nil)
    assert SentryFilter.before_send(no_exception) == no_exception
  end

  describe "malformed LiveView joins (#700)" do
    # The *real* exception, raised by the dependency, rather than a struct built
    # to match the filter. That is the whole value of this test: the filter names
    # a module and a function inside `phoenix_live_view`, and if a version bump
    # renames or reshapes either, a hand-built struct would keep passing while
    # the flood quietly resumed.
    defp join_crash(url) do
      Phoenix.LiveView.Route.live_link_info_without_checks(
        KilnCMSWeb.Endpoint,
        KilnCMSWeb.Router,
        url
      )
    rescue
      error -> error
    end

    test "drops the crash a non-binary url produces" do
      # `%{"url" => nil}` and `%{"url" => 42}` are the payloads from the issue's
      # probe; both reach this call, which accepts only a binary or a `%URI{}`.
      for bad <- [nil, 42, %{}] do
        crash = join_crash(bad)

        assert %FunctionClauseError{} = crash
        assert SentryFilter.before_send(event(original_exception: crash)) == nil
      end
    end

    test "a well-formed url does not crash at all, so nothing is being masked" do
      refute match?(%FunctionClauseError{}, join_crash("/"))
    end

    test "keeps a FunctionClauseError from anywhere else" do
      # The narrowness is the point: dropping every `FunctionClauseError`, or
      # everything from `Phoenix.LiveView.Channel`, would swallow real LiveView
      # bugs — which is the opposite of what this exists to protect.
      # A genuine `FunctionClauseError` from an unrelated module. Built by
      # calling a function with arguments no clause matches — `Date.new/4`
      # requires integers — rather than by constructing the struct, so it
      # carries the same shape a real one would.
      elsewhere =
        try do
          Date.new(:not_a_year, 1, 1)
        rescue
          error -> error
        end

      passed = event(original_exception: elsewhere)

      assert %FunctionClauseError{} = elsewhere
      assert SentryFilter.before_send(passed) == passed
    end
  end
end
