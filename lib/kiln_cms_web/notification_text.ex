defmodule KilnCMSWeb.NotificationText do
  @moduledoc """
  The human sentence for a persisted notification (#1320).

  One module, because two surfaces render the same rows — `/editor/inbox` and
  the top bar's bell — and a notification that reads "New comment" in one place
  and "Someone commented" in the other is two features. It is also the place
  the wording is *complete*: every event in
  `KilnCMS.Notifications.Notification`'s `one_of` constraint has a clause here,
  and the test reads that constraint back, because a headline falling through
  to a bare event atom is a defect the reader sees.

  ## Two sentences per event, not one with a stand-in name

  Actor-less events are real rather than an omission: scheduled publishing has
  no acting user, and an editorial-intelligence reaction deliberately does not
  borrow one (#946). So each event carries its own actor-less wording instead
  of interpolating something like "An editor", which would be a claim about a
  person who does not exist.

  Spelled out per clause rather than run through one `String.replace/3` helper.
  The helper compiled and read more compactly, and it was wrong: `gettext/1`
  with no bindings logs `missing Gettext bindings: [:who]` on **every render**
  and leaves the locale's own interpolation unresolved, so a translation that
  moves `%{who}` — which several naturally do — would have broken. The binding
  belongs at the `gettext/2` call.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @doc "One line naming what happened, with the actor's name when there is one."
  @spec headline(map()) :: String.t()
  def headline(%{event: :submitted_for_review} = notification) do
    case actor(notification) do
      nil -> gettext("Review requested")
      who -> gettext("%{who} asked for a review", who: who)
    end
  end

  # No actor-carrying variant: `:published` is dispatched actor-less by design
  # (it also covers scheduled publishing, where there is nobody to name), so a
  # row never has a name to render here.
  def headline(%{event: :published}), do: gettext("Published")

  def headline(%{event: :returned_to_draft} = notification) do
    case actor(notification) do
      nil -> gettext("Changes requested")
      who -> gettext("%{who} requested changes", who: who)
    end
  end

  def headline(%{event: :comment_added} = notification) do
    case actor(notification) do
      nil -> gettext("New comment")
      who -> gettext("%{who} commented", who: who)
    end
  end

  def headline(%{event: :comment_resolved} = notification) do
    case actor(notification) do
      nil -> gettext("Thread resolved")
      who -> gettext("%{who} resolved a thread", who: who)
    end
  end

  def headline(%{event: :comment_mention} = notification) do
    case actor(notification) do
      nil -> gettext("You were mentioned")
      who -> gettext("%{who} mentioned you", who: who)
    end
  end

  def headline(%{event: :task_assigned} = notification) do
    case actor(notification) do
      nil -> gettext("Task assigned")
      who -> gettext("%{who} assigned you a task", who: who)
    end
  end

  # `""` is treated as absent, not as a name: `KilnCMS.Notifications` only ever
  # stores a non-empty `name` or nil (privacy #214 — never the email
  # local-part), but a blank string rendered as an actor would produce a
  # sentence with a hole in it.
  defp actor(%{actor_name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp actor(_notification), do: nil
end
