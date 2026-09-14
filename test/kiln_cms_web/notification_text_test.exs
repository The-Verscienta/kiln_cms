defmodule KilnCMSWeb.NotificationTextTest do
  @moduledoc """
  Every notification event has a sentence, and it stays level with the
  resource's own list of events (#1320).

  The second test is the one that earns its keep: the wording lives in one
  module precisely so the inbox and the bell agree, and the way that breaks is
  somebody adding an event to `Notification`'s `one_of` constraint and not
  here. A headline falling through to a bare atom is a defect the reader sees,
  so the constraint is read back rather than restated.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.NotificationText

  defp events do
    KilnCMS.Notifications.Notification
    |> Ash.Resource.Info.attribute(:event)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
  end

  test "each event reads as a sentence naming who did it" do
    assert NotificationText.headline(%{event: :submitted_for_review, actor_name: "Ada"}) ==
             "Ada asked for a review"

    assert NotificationText.headline(%{event: :returned_to_draft, actor_name: "Ada"}) ==
             "Ada requested changes"

    assert NotificationText.headline(%{event: :comment_added, actor_name: "Ada"}) ==
             "Ada commented"

    assert NotificationText.headline(%{event: :comment_resolved, actor_name: "Ada"}) ==
             "Ada resolved a thread"

    assert NotificationText.headline(%{event: :comment_mention, actor_name: "Ada"}) ==
             "Ada mentioned you"

    assert NotificationText.headline(%{event: :task_assigned, actor_name: "Ada"}) ==
             "Ada assigned you a task"
  end

  test "the actor's name is interpolated by gettext, not patched in afterwards" do
    # A `gettext/1` call with no bindings logs `missing Gettext bindings:
    # [:who]` on every render and leaves the placeholder for a `String.replace`
    # to patch — which also means a locale that moves `%{who}` within its own
    # sentence silently stops working. `capture_log` is the assertion: the
    # render must be quiet.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert NotificationText.headline(%{event: :comment_mention, actor_name: "Ada"}) ==
                 "Ada mentioned you"
      end)

    refute log =~ "missing Gettext bindings"
  end

  test "an actor-less event gets its own sentence, not a stand-in name" do
    # Scheduled publishing has no acting user; automation deliberately does not
    # borrow one (#946). Neither may be rendered as if a person did it. A blank
    # name counts as absent — a sentence with a hole in it is worse than the
    # neutral one.
    for actor_name <- [nil, "", "   "] do
      assert NotificationText.headline(%{event: :published, actor_name: actor_name}) ==
               "Published"

      assert NotificationText.headline(%{event: :comment_added, actor_name: actor_name}) ==
               "New comment"

      assert NotificationText.headline(%{event: :task_assigned, actor_name: actor_name}) ==
               "Task assigned"
    end
  end

  test "every event the resource allows has a clause here" do
    # A missing clause is a `FunctionClauseError`, not a falsy return, so the
    # raise is caught and reported as the thing it actually is — otherwise the
    # next person to add an event reads a stacktrace instead of an
    # instruction.
    missing = Enum.reject(events(), &has_sentence?/1)

    assert missing == [],
           """
           These events are allowed by `KilnCMS.Notifications.Notification`'s
           `one_of` constraint but have no sentence in
           `KilnCMSWeb.NotificationText.headline/1`, so the inbox and the bell
           would crash rendering them:

           #{Enum.map_join(missing, "\n", &"  * #{inspect(&1)}")}
           """
  end

  defp has_sentence?(event) do
    case NotificationText.headline(%{event: event, actor_name: nil}) do
      headline when is_binary(headline) -> headline != ""
      _other -> false
    end
  rescue
    FunctionClauseError -> false
  end
end
