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
end
