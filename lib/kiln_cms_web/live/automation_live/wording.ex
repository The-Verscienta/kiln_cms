defmodule KilnCMSWeb.AutomationLive.Wording do
  @moduledoc """
  The words the automation builder uses for a rule: what each trigger and
  reaction is called, how the reaction cards describe themselves, and the one
  plain sentence a whole rule reads as ("When Post content is published, email
  team@example.com.").

  The sentence is the rule's name when the admin leaves the name blank, the
  preview under the form while it is being built, and the line in the rules
  list — so what a rule does is said the same way everywhere, and nowhere as
  `post.published → send_email`.

  Which triggers and reactions exist is `KilnCMS.Automation.Rule`'s business;
  this module only words them. `automation_live_test.exs` fails when a trigger
  or reaction has no wording here, so a new one can't reach the builder as a
  raw atom.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Automation.Rule

  # Verbs that only ever fire for editorial tasks (`task.assigned`,
  # `task.overdue`): a rule on one reads "a task", whatever it's scoped to.
  @task_triggers [:assigned, :overdue]

  @doc """
  The trigger as the end of "When <content> …": "is published".

  `nil` for a trigger with no wording — the test that forbids that is the
  real guard.
  """
  @spec trigger_phrase(atom()) :: String.t() | nil
  def trigger_phrase(:published), do: gettext("is published")
  def trigger_phrase(:unpublished), do: gettext("is unpublished")
  def trigger_phrase(:updated), do: gettext("is updated")
  def trigger_phrase(:in_review), do: gettext("is submitted for review")
  def trigger_phrase(:returned_to_draft), do: gettext("is sent back to draft")
  def trigger_phrase(:assigned), do: gettext("is assigned")
  def trigger_phrase(:overdue), do: gettext("is overdue")
  def trigger_phrase(:health_overdue), do: gettext("is past its review date")
  def trigger_phrase(:health_expired), do: gettext("has expired")
  def trigger_phrase(_trigger), do: nil

  @doc """
  The trigger picker's options, grouped the way an admin thinks about them:
  things someone does to content, things that happen to a task, and things
  that happen because time passed.
  """
  @spec trigger_options() :: [{String.t(), [{String.t(), atom()}]}]
  def trigger_options do
    groups = [
      {gettext("Editorial changes"), &(&1 not in @task_triggers and not health?(&1))},
      {gettext("Tasks"), &(&1 in @task_triggers)},
      {gettext("Content health"), &health?/1}
    ]

    groups
    |> Enum.map(fn {label, keep?} ->
      {label, for(t <- Rule.triggers(), keep?.(t), do: {phrase(t), t})}
    end)
    |> Enum.reject(fn {_label, options} -> options == [] end)
  end

  defp health?(trigger), do: trigger in [:health_overdue, :health_expired]

  @doc """
  One reaction card: `%{label, description, icon, group}`, or `nil` for a
  reaction with no wording.

  Icons are written out whole (`"hero-envelope"`) — Tailwind builds an icon's
  class only from a literal it finds in the source.
  """
  @spec action(atom()) :: map() | nil
  def action(:send_email),
    do: %{
      label: gettext("Send an email"),
      description: gettext("Email a note about the change to an address."),
      icon: "hero-envelope",
      group: :notify
    }

  def action(:newsletter),
    do: %{
      label: gettext("Send the newsletter"),
      description: gettext("Mail the published piece to newsletter subscribers."),
      icon: "hero-newspaper",
      group: :notify
    }

  def action(:social_post),
    do: %{
      label: gettext("Post to social media"),
      description: gettext("Announce it on Bluesky or Mastodon."),
      icon: "hero-megaphone",
      group: :notify
    }

  def action(:broadcast),
    do: %{
      label: gettext("Broadcast an internal event"),
      description: gettext("Signal plugins and dashboards listening inside Kiln."),
      icon: "hero-signal",
      group: :notify
    }

  def action(:create_task),
    do: %{
      label: gettext("Create a task"),
      description: gettext("Put a follow-up in the author's task list."),
      icon: "hero-clipboard-document-check",
      group: :review
    }

  def action(:flag_duplicates),
    do: %{
      label: gettext("Flag near-duplicates"),
      description: gettext("Find existing content that covers the same ground."),
      icon: "hero-document-duplicate",
      group: :review
    }

  def action(:suggest_tags),
    do: %{
      label: gettext("Suggest tags"),
      description: gettext("Propose tags for an editor to accept."),
      icon: "hero-tag",
      group: :review
    }

  def action(:suggest_links),
    do: %{
      label: gettext("Suggest internal links"),
      description: gettext("Point out related pages worth linking to."),
      icon: "hero-link",
      group: :review
    }

  def action(:suggest_metadata),
    do: %{
      label: gettext("Draft SEO metadata"),
      description: gettext("Draft a title and description; nothing changes until accepted."),
      icon: "hero-sparkles",
      group: :review
    }

  def action(:invalidate_cache),
    do: %{
      label: gettext("Clear the cache"),
      description: gettext("Make sure visitors get the newest version right away."),
      icon: "hero-arrow-path",
      group: :site
    }

  def action(:reindex),
    do: %{
      label: gettext("Rebuild the page"),
      description: gettext("Regenerate the published page from the latest content."),
      icon: "hero-arrow-path-rounded-square",
      group: :site
    }

  def action(_action), do: nil

  # The order an admin scans the cards in: the everyday reaction of each group
  # first, the specialist one (an internal broadcast only a plugin listens
  # for) last. A reaction missing here sorts after every listed one.
  @card_order [
    :send_email,
    :newsletter,
    :social_post,
    :broadcast,
    :create_task,
    :flag_duplicates,
    :suggest_tags,
    :suggest_links,
    :suggest_metadata,
    :invalidate_cache,
    :reindex
  ]

  @doc "The reaction cards in their groups, everyday ones first."
  @spec action_groups() :: [{String.t(), [{atom(), map()}]}]
  def action_groups do
    groups = [
      notify: gettext("Notify people"),
      review: gettext("Review & follow-up"),
      site: gettext("Keep the site fresh")
    ]

    cards =
      Rule.action_kinds()
      |> Enum.sort_by(&(Enum.find_index(@card_order, fn known -> known == &1 end) || 999))
      |> Enum.map(&{&1, card(&1)})

    groups
    |> Enum.map(fn {group, label} ->
      {label, Enum.filter(cards, fn {_action, card} -> card.group == group end)}
    end)
    |> Enum.reject(fn {_label, cards} -> cards == [] end)
  end

  # A reaction with no wording still gets a card (in the last group) rather
  # than vanishing from the builder.
  defp card(action) do
    action(action) ||
      %{label: Phoenix.Naming.humanize(action), description: nil, icon: "hero-bolt", group: :site}
  end

  @doc """
  The whole rule as one sentence.

  `rule` is anything with `:trigger_event`, `:content_type`, `:action` and
  `:config` (a `Rule`, or the builder's draft). `names` resolves ids to what
  an admin calls them — `%{types: %{"post" => "Post"}, users: %{id => name},
  segments: %{id => name}}` — and an id it can't resolve is left out of the
  sentence rather than shown raw.
  """
  @spec summary(map(), map()) :: String.t()
  def summary(rule, names \\ %{}) do
    # `Map.get`, not `rule[:key]`: a `%Rule{}` struct has no Access.
    trigger = Map.get(rule, :trigger_event)
    config = Map.get(rule, :config) || %{}

    gettext("When %{subject} %{event}, %{reaction}.",
      subject: subject(Map.get(rule, :content_type), trigger, names),
      event: phrase(trigger),
      reaction: reaction(Map.get(rule, :action), config, names)
    )
  end

  defp subject(_type, trigger, _names) when trigger in @task_triggers, do: gettext("a task")
  defp subject(type, _trigger, _names) when type in [nil, ""], do: gettext("any content")
  defp subject("task", _trigger, _names), do: gettext("a task")

  defp subject(type, _trigger, names) do
    gettext("%{type} content", type: get_in(names, [:types, type]) || type)
  end

  defp phrase(trigger), do: trigger_phrase(trigger) || Phoenix.Naming.humanize(trigger || "")

  defp reaction(:send_email, %{"to" => to}, _names), do: gettext("email %{to}", to: to)
  defp reaction(:send_email, _config, _names), do: gettext("send an email")

  defp reaction(:newsletter, config, names) do
    case name(names, :segments, config["segment_id"]) do
      nil -> gettext("send the newsletter to all subscribers")
      segment -> gettext("send the newsletter to %{segment}", segment: segment)
    end
  end

  defp reaction(:social_post, %{"provider" => provider}, _names),
    do: gettext("post to %{network}", network: Phoenix.Naming.humanize(provider))

  defp reaction(:social_post, _config, _names), do: gettext("post to social media")

  defp reaction(:broadcast, config, _names),
    do: gettext("broadcast on “%{topic}”", topic: config["topic"] || "automation")

  defp reaction(:create_task, _config, _names), do: gettext("create a task for the author")
  defp reaction(:invalidate_cache, _config, _names), do: gettext("clear the cache")
  defp reaction(:reindex, _config, _names), do: gettext("rebuild the page")

  defp reaction(action, config, names)
       when action in [:flag_duplicates, :suggest_tags, :suggest_links, :suggest_metadata] do
    gettext("%{finding}, %{delivery}",
      finding: finding(action),
      delivery: delivery(config, names)
    )
  end

  # A reaction added to `Rule` before it is worded here.
  defp reaction(action, _config, _names),
    do: String.downcase(Phoenix.Naming.humanize(action || ""))

  defp finding(:flag_duplicates), do: gettext("flag near-duplicates")
  defp finding(:suggest_tags), do: gettext("suggest tags")
  defp finding(:suggest_links), do: gettext("suggest internal links")
  defp finding(:suggest_metadata), do: gettext("draft SEO metadata")

  defp delivery(config, names) do
    case config["deliver_as"] || "email" do
      "comment" ->
        gettext("left as a comment")

      "task" ->
        case name(names, :users, config["assignee"]) do
          nil -> gettext("as a task")
          person -> gettext("as a task for %{person}", person: person)
        end

      _email ->
        case config["to"] do
          nil -> gettext("sent by email")
          to -> gettext("emailed to %{to}", to: to)
        end
    end
  end

  defp name(_names, _kind, nil), do: nil
  defp name(names, kind, id), do: get_in(names, [kind, id])
end
