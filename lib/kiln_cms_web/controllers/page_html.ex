defmodule KilnCMSWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use KilnCMSWeb, :html

  embed_templates "page_html/*"

  # The access-denied page (#2143). `needs` is the whitelisted
  # `KilnCMSWeb.AccessDenied` value or nil; the viewer's role is `nil`
  # (signed out), `:viewer`, `:editor`, `:admin` or `:platform`.
  defp needs_label(:editor), do: gettext("editor")
  defp needs_label(:admin), do: gettext("admin")
  defp needs_label(:platform), do: gettext("platform admin")

  defp denied_heading(nil), do: gettext("You don't have access to this page")

  defp denied_heading(needs),
    do: gettext("This page needs %{role} access", role: needs_label(needs))

  defp denied_intro(:editor),
    do: gettext("Editors and admins of this site can open it. Your account has a different role.")

  defp denied_intro(:admin),
    do: gettext("Only admins of this site can open it. Your account has a different role.")

  defp denied_intro(:platform),
    do:
      gettext(
        "It manages settings that apply to the whole installation, so only a platform admin can open it, not even an admin of a single site."
      )

  defp denied_intro(nil),
    do: gettext("It is limited to people with a role your account does not have on this site.")

  defp role_name(:platform), do: gettext("platform admin")
  defp role_name(:admin), do: gettext("admin")
  defp role_name(:editor), do: gettext("editor")
  defp role_name(:viewer), do: gettext("viewer")

  defp role_can(:viewer),
    do:
      gettext(
        "A viewer can read content and manage their own account, but cannot use the editing console."
      )

  defp role_can(:editor),
    do:
      gettext(
        "An editor can write and edit content, manage media and use the editing tools, but cannot change site settings."
      )

  defp role_can(role) when role in [:admin, :platform],
    do: gettext("An admin can use the whole editing console for this site.")

  # The home page's lists, kept here rather than inline so the template reads
  # as layout. Every claim names a surface that exists in the router today —
  # this page is the first description of Kiln most visitors read, and an
  # overclaim here is one they find out about after installing (#1324).

  # One home-page screenshot: WebP at each width in a `srcset`, with the 1440w
  # JPEG as the fallback `src`. Every URL goes through `~p` so it takes the
  # digest manifest (long cache headers). Below-the-fold shots are lazy; the
  # hero (`hero`) is not and is fetched at high priority (#2165).
  attr :name, :string, required: true
  attr :widths, :list, required: true
  attr :sizes, :string, required: true
  attr :alt, :string, required: true
  attr :class, :string, default: nil
  attr :hero, :boolean, default: false

  defp home_shot(assigns) do
    ~H"""
    <picture>
      <source
        type="image/webp"
        sizes={@sizes}
        srcset={Enum.map_join(@widths, ", ", &"#{~p"/images/home/#{"#{@name}-#{&1}.webp"}"} #{&1}w")}
      />
      <img
        src={~p"/images/home/#{"#{@name}.jpg"}"}
        width="1440"
        height="900"
        loading={if @hero, do: "eager", else: "lazy"}
        fetchpriority={if @hero, do: "high"}
        decoding="async"
        class={["block w-full", @class]}
        alt={@alt}
      />
    </picture>
    """
  end

  # Screenshots under priv/static/images/home/, captured by
  # e2e/screenshots/home.spec.js and derived by scripts/optimize_home_images.sh;
  # `editor` is the hero, not in this list.
  defp tour_shots do
    [
      %{
        name: "content",
        title: gettext("All your content in one list"),
        text: gettext("Pages and posts with their workflow state, author and last change."),
        alt: gettext("The KilnCMS content list, showing pages and posts with their states.")
      },
      %{
        name: "calendar",
        title: gettext("A publishing calendar"),
        text: gettext("See what goes live when, and drag an item to reschedule it."),
        alt: gettext("The KilnCMS publishing calendar with scheduled posts.")
      },
      %{
        name: "media",
        title: gettext("A media library"),
        text: gettext("Uploads get responsive variants, alt text and tags."),
        alt: gettext("The KilnCMS media library with a grid of images.")
      }
    ]
  end

  # The editorial workflow guide (#2158), on GitHub like "How it works": the
  # stock home page ships to every install, and a relative /docs link would
  # 404 wherever the guides are not published; GitHub also always shows the
  # guide's screenshots.
  @workflow_guide "https://github.com/The-Verscienta/kiln_cms/blob/main/docs/editorial-workflow.md"

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
          ),
        href: @workflow_guide,
        link: gettext("Walk through the workflow")
      },
      %{
        icon: "hero-shield-check",
        title: gettext("Roles and permissions"),
        text:
          gettext(
            "Admins, editors and viewers, enforced by policies on every read and write — in the editor and the APIs alike."
          ),
        href: @workflow_guide <> "#who-can-do-what",
        link: gettext("See who can do what")
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
