defmodule KilnCMSWeb.NotificationText do
  @moduledoc """
  The human sentence for a persisted notification (#1320).

  One module, because two surfaces render the same rows — `/editor/inbox` and
  the top bar's bell — and a notification that reads "New comment" in one place
  and "Someone commented" in the other is two features. It is also the place
  the wording is *complete*: every event in
  `KilnCMS.Notifications.Notification`'s `one_of` constraint has a clause here,
  and the test pins that, because a headline falling through to a bare event
  atom is a defect the reader sees.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @doc """
  One line naming what happened, with the actor's name when there is one.

  Actor-less events are real rather than an omission: scheduled publishing has
  no acting user, and automation deliberately does not borrow one (#946). Each
  gets its own sentence instead of a stand-in like "An editor", which would be
  a claim about a person who does not exist.
  """
  @spec headline(map()) :: String.t()
  def headline(%{event: :submitted_for_review} = notification),
    do:
      with_actor(notification, gettext("%{who} asked for a review"), gettext("Review requested"))

  def headline(%{event: :published}), do: gettext("Published")

  def headline(%{event: :returned_to_draft} = notification),
    do:
      with_actor(notification, gettext("%{who} requested changes"), gettext("Changes requested"))

  def headline(%{event: :comment_added} = notification),
    do: with_actor(notification, gettext("%{who} commented"), gettext("New comment"))

  def headline(%{event: :comment_resolved} = notification),
    do: with_actor(notification, gettext("%{who} resolved a thread"), gettext("Thread resolved"))

  def headline(%{event: :comment_mention} = notification),
    do: with_actor(notification, gettext("%{who} mentioned you"), gettext("You were mentioned"))

  def headline(%{event: :task_assigned} = notification),
    do: with_actor(notification, gettext("%{who} assigned you a task"), gettext("Task assigned"))

  # Substituted rather than passed to `gettext/2` as a binding, because the
  # translator's msgid is the template: `gettext("%{who} commented", who: name)`
  # and this produce the same catalog entry, and doing it here keeps one
  # function able to take either form.
  defp with_actor(%{actor_name: name}, template, _actorless) when is_binary(name) and name != "",
    do: String.replace(template, "%{who}", name)

  defp with_actor(_notification, _template, actorless), do: actorless
end
