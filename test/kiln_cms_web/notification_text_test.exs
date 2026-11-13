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
           would render them as the bare fallback:

           #{Enum.map_join(missing, "\n", &"  * #{inspect(&1)}")}
           """
  end

  test "an event with no sentence of its own reads as the neutral fallback" do
    assert NotificationText.headline(%{event: :from_a_newer_release, actor_name: "Ada"}) ==
             NotificationText.fallback()
  end

  test "a registration notice names no applicant" do
    assert NotificationText.headline(%{event: :registration_pending, actor_name: nil}) ==
             "Registrations waiting for approval"
  end

  describe "a security row's excerpt (#2642)" do
    alias KilnCMS.Security.Alerts
    alias KilnCMS.Security.AlertText

    test "every alert kind and every notice change has a label of its own" do
      for kind <- Alerts.site_kinds() ++ Alerts.platform_kinds() do
        refute AlertText.kind_label(kind) == AlertText.kind_label("from_a_newer_release"),
               "#{kind} has no label"
      end

      for change <- Alerts.notice_changes() do
        refute AlertText.change_label(change) == AlertText.change_label("from_a_newer_release"),
               "#{change} has no label"
      end
    end

    test "is said from its details for every security event" do
      alert = %{
        event: :security_alert,
        excerpt: "stored",
        details: %{"phase" => "alert", "kind" => "lockout", "ip" => "203.0.113.0/24"}
      }

      notice = %{
        event: :security_notice,
        excerpt: "stored",
        details: %{"phase" => "notice", "change" => "webhook_removed"}
      }

      assert NotificationText.excerpt(alert) ==
               "An account was locked out (from 203.0.113.0/24)"

      assert NotificationText.excerpt(notice) ==
               "A webhook that receives security alerts was deleted"

      Gettext.with_locale(KilnCMSWeb.Gettext, "fr", fn ->
        assert NotificationText.excerpt(alert) ==
                 "Un compte a été verrouillé (depuis 203.0.113.0/24)"
      end)
    end

    test "a blocked address names the rule, never an address; a key over a limit its kind" do
      blocked = %{
        event: :security_alert,
        excerpt: "stored",
        details: %{
          "phase" => "alert",
          "kind" => "blocked_ip",
          "rule" => "203.0.113.0/24",
          "event_type" => "ip_block_refused"
        }
      }

      assert NotificationText.excerpt(blocked) ==
               "A blocked address was refused (rule 203.0.113.0/24)"

      # Without a rule (no event left to name it) it is the bare label.
      assert NotificationText.excerpt(%{
               blocked
               | details: Map.delete(blocked.details, "rule")
             }) == "A blocked address was refused"

      assert NotificationText.excerpt(%{
               event: :security_alert,
               excerpt: "stored",
               details: %{
                 "phase" => "alert",
                 "kind" => "api_key_rate_limited",
                 "ip" => "203.0.113.0/24"
               }
             }) == "An API key hit a rate limit (from 203.0.113.0/24)"

      # A reuse row stored before the rate-limit kind existed reads as it did.
      assert NotificationText.excerpt(%{
               event: :security_alert,
               excerpt: "stored",
               details: %{
                 "phase" => "alert",
                 "kind" => "api_key_abuse",
                 "event_type" => "api_key_reuse_detected"
               }
             }) == "A rotated API key was used again"
    end

    test "a kind or change from a newer release reads neutrally" do
      assert NotificationText.excerpt(%{
               event: :security_alert,
               excerpt: "stored",
               details: %{"phase" => "alert", "kind" => "from_a_newer_release"}
             }) == "Security alert"

      assert NotificationText.excerpt(%{
               event: :security_notice,
               excerpt: "stored",
               details: %{"phase" => "notice", "change" => "from_a_newer_release"}
             }) == "Security alerts were made quieter"
    end

    test "a row without details, or any other event, shows the stored excerpt" do
      assert NotificationText.excerpt(%{event: :security_alert, excerpt: "stored", details: nil}) ==
               "stored"

      assert NotificationText.excerpt(%{
               event: :comment_added,
               excerpt: "a comment",
               details: %{"phase" => "alert", "kind" => "lockout"}
             }) == "a comment"

      assert NotificationText.excerpt(%{event: :published, excerpt: nil}) == nil
    end
  end

  # The catch-all clause answers `fallback/0` for any event, so reaching it
  # is what "no sentence" means now.
  defp has_sentence?(event) do
    case NotificationText.headline(%{event: event, actor_name: nil}) do
      headline when is_binary(headline) ->
        headline != "" and headline != NotificationText.fallback()

      _other ->
        false
    end
  rescue
    FunctionClauseError -> false
  end
end
