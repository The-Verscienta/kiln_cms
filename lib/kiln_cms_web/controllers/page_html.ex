defmodule KilnCMSWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use KilnCMSWeb, :html

  embed_templates "page_html/*"

  # The home page's lists, kept here rather than inline so the template reads
  # as layout. Every claim names a surface that exists in the router today —
  # this page is the first description of Kiln most visitors read, and an
  # overclaim here is one they find out about after installing (#1324).

  # Screenshots under priv/static/images/home/, captured by
  # e2e/screenshots/home.spec.js; `editor.jpg` is the hero, not in this list.
  defp tour_shots do
    [
      %{
        src: ~p"/images/home/content.jpg",
        title: gettext("All your content in one list"),
        text: gettext("Pages and posts with their workflow state, author and last change."),
        alt: gettext("The KilnCMS content list, showing pages and posts with their states.")
      },
      %{
        src: ~p"/images/home/calendar.jpg",
        title: gettext("A publishing calendar"),
        text: gettext("See what goes live when, and drag an item to reschedule it."),
        alt: gettext("The KilnCMS publishing calendar with scheduled posts.")
      },
      %{
        src: ~p"/images/home/media.jpg",
        title: gettext("A media library"),
        text: gettext("Uploads get responsive variants, alt text and tags."),
        alt: gettext("The KilnCMS media library with a grid of images.")
      }
    ]
  end

  defp features do
    [
      %{
        icon: "hero-pencil-square",
        title: gettext("Block editor"),
        text:
          gettext(
            "TipTap rich text, drag-and-drop blocks, live preview, and version restore — all in LiveView."
          )
      },
      %{
        icon: "hero-check-badge",
        title: gettext("Editorial workflow"),
        text:
          gettext(
            "Draft, review and publish, with scheduled publishing and content releases that ship several changes at once."
          )
      },
      %{
        icon: "hero-shield-check",
        title: gettext("Roles and permissions"),
        text:
          gettext(
            "Admins, editors and viewers, enforced by policies on every read and write — in the editor and the APIs alike."
          )
      },
      %{
        icon: "hero-globe-alt",
        title: gettext("Headless delivery"),
        text:
          gettext(
            "AshGraphql and AshJsonApi expose your content model to any frontend, with signed preview tokens for drafts."
          )
      },
      %{
        icon: "hero-magnifying-glass",
        title: gettext("Search built in"),
        text:
          gettext(
            "PostgreSQL full-text search, with optional semantic and hybrid ranking on pgvector."
          )
      },
      %{
        icon: "hero-photo",
        title: gettext("Media pipeline"),
        text:
          gettext(
            "Uploads are checked by their contents, stripped of location metadata, and resized into responsive variants."
          )
      }
    ]
  end

  defp extras do
    [
      gettext("Translations"),
      gettext("Version history"),
      gettext("Navigation menus"),
      gettext("Redirects"),
      gettext("Forms"),
      gettext("Newsletters"),
      gettext("Webhooks"),
      gettext("Analytics"),
      gettext("A/B experiments"),
      gettext("Compliance reports"),
      gettext("MCP server for AI assistants")
    ]
  end

  defp developer_points do
    [
      gettext("GraphQL and JSON:API, both generated from one content model"),
      gettext("Only published content is readable without a key"),
      gettext("Webhooks when content changes"),
      gettext("An OpenAPI spec and a browsable API explorer")
    ]
  end
end
