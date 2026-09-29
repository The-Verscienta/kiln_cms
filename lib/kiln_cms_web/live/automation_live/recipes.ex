defmodule KilnCMSWeb.AutomationLive.Recipes do
  @moduledoc """
  Ready-made starting points for the automation builder: "Email me when
  something is published", "Create a task when content goes stale", and so on.

  A recipe is only a set of form values. Picking one fills the builder, and
  the admin reviews it, fills in what the recipe can't know (which social
  network, whose inbox), and saves it like any rule they built by hand — so a
  recipe can never save anything the builder and `ActionConfig` wouldn't.
  Nothing here is stored; a rule made from a recipe doesn't remember it.

  `automation_live_test.exs` checks every recipe against `Rule`'s triggers and
  reactions and `ActionConfig`'s shape table, so a recipe can't name a key or
  a reaction that has since gone.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @doc """
  The recipes, for a builder whose admin is reachable at `email` and whose
  site has the content types in `types` (a list of type names).

  Each is `%{id, title, description, icon, params}`, where `params` is shaped
  like the builder's own `rule[...]` form params. A recipe that reads best
  scoped to posts falls back to "any content" on a site with no `post` type.
  """
  @spec all(%{email: String.t() | nil, types: [String.t()]}) :: [map()]
  def all(%{email: email, types: types}) do
    post = if "post" in types, do: "post", else: ""

    [
      %{
        id: "email-on-publish",
        title: gettext("Email me when something is published"),
        description: gettext("A note in your inbox each time content goes live."),
        icon: "hero-envelope",
        params: rule(:published, "", :send_email, compact(%{"to" => email}))
      },
      %{
        id: "task-when-stale",
        title: gettext("Create a task when content goes stale"),
        description: gettext("Past its review date? It lands in the author's task list."),
        icon: "hero-clipboard-document-check",
        params: rule(:health_overdue, "", :create_task, %{})
      },
      %{
        id: "social-on-publish",
        title: gettext("Announce new posts on social media"),
        description: gettext("Post to Bluesky or Mastodon when a post is published."),
        icon: "hero-megaphone",
        params: rule(:published, post, :social_post, %{})
      },
      %{
        id: "newsletter-on-publish",
        title: gettext("Send new posts to subscribers"),
        description: gettext("Mail each published post as a newsletter."),
        icon: "hero-newspaper",
        params: rule(:published, post, :newsletter, %{})
      },
      %{
        id: "duplicates-in-review",
        title: gettext("Check for near-duplicates at review"),
        description: gettext("Leave a comment when a draft covers ground already covered."),
        icon: "hero-document-duplicate",
        params: rule(:in_review, "", :flag_duplicates, %{"deliver_as" => "comment"})
      },
      %{
        id: "cache-on-update",
        title: gettext("Keep the live site current"),
        description: gettext("Clear the cache whenever published content changes."),
        icon: "hero-arrow-path",
        params: rule(:updated, "", :invalidate_cache, %{})
      }
    ]
  end

  @doc "The recipe with `id`, or `nil`."
  @spec get(String.t(), map()) :: map() | nil
  def get(id, context), do: Enum.find(all(context), &(&1.id == id))

  defp rule(trigger, content_type, action, config) do
    %{
      "trigger_event" => to_string(trigger),
      "content_type" => content_type,
      "action" => to_string(action),
      "config" => config
    }
  end

  # An admin with no email on file gets an empty "Send to" to fill, not `nil`.
  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> v in [nil, ""] end) |> Map.new()
end
