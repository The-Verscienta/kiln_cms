defmodule KilnCMSWeb.ConsoleNav do
  @moduledoc """
  The console's navigation, as data (#1319).

  `Layouts.console_nav/1` draws this and the ⌘K palette searches it, so the two
  are the same list by construction: a screen that is added here is reachable by
  name from the palette on the day it is added, and one an actor may not open is
  absent from both. The alternative — a second, palette-shaped copy of the item
  list — is the shape that goes stale silently, and this codebase has been
  bitten by it before (the editor `@` roster, #1431).

  Three groups come back from `nav/2`:

    * `:author` — the day-to-day editorial screens, drawn ungrouped at the top.
    * `:configure_groups` — the admin screens, in collapsible sections. The
      last one is `operator?: true`: the instance-wide screens (Team, Billing,
      Mail, API keys, Backups, System) that `platform_admin_user?/1` gates, set
      apart because "restore last night's backup" and "fix a typo in a footer"
      are not the same job (#1319).
    * `:plugin` — whatever plugins contributed, drawn last.

  Group `key`s are not decoration: the sidebar's collapse state is stored
  against them in `localStorage` and applied from `<html data-nav-collapsed>`,
  and `assets/css/app.css` carries one rule per key. `console_nav_test.exs`
  fails if a key here has no rule there.
  """

  use Gettext, backend: KilnCMSWeb.Gettext
  use KilnCMSWeb, :verified_routes

  alias KilnCMS.Accounts.Scoping
  alias KilnCMSWeb.LiveUserAuth

  @doc """
  The nav for `user` on `org`, already filtered to what they may open.

  `org` may be nil: `Layouts.console/1` declares `attr :current_org, :map,
  default: nil`, so nil is inside that component's contract and is resolved
  here, not by the tenant resolver (which raises on a missing assign, #563).
  """
  def nav(user, org) do
    # Effective capability tier on the CURRENT site (#419) — a global editor
    # demoted (or promoted) by an org membership sees the nav for that tier.
    # The tier only picks which links render; every action behind them
    # re-authorizes against the real org, so a wrong answer here is cosmetic.
    role = Scoping.effective_tier(user, org || KilnCMS.Accounts.default_org_id())

    # The instance-wide consoles gate their pages on the GLOBAL role
    # (#419/#1160), not on the per-org tier above. A per-org admin passes
    # `role == :admin` and would be shown links those pages only bounce, so the
    # links ask the same predicate the pages do.
    platform_admin? = LiveUserAuth.platform_admin_user?(user)

    %{
      author: author_items(),
      configure_groups: configure_groups(role, platform_admin?),
      plugin: plugin_items(role)
    }
  end

  @doc """
  Every console screen `user` may open on `org`, flattened for the ⌘K palette.

  Each entry carries the `section` it sits under, so a result can say where the
  screen lives — "Backups · Operations" answers "am I about to touch the
  instance?" before the click, not after.
  """
  def destinations(user, org) do
    %{author: author, configure_groups: groups, plugin: plugin} = nav(user, org)

    grouped =
      Enum.flat_map(groups, fn group ->
        Enum.map(group.items, &Map.put(&1, :section, group.label))
      end)

    author ++ grouped ++ plugin
  end

  @doc """
  The destinations whose name (or section name) contains `query`.

  Case- and accent-insensitive substring matching, not the trigram search the
  content half of the palette runs: this list is ~30 items an admin already
  half-remembers the name of, and an admin who types "back" wants Backups at
  the first keystroke, not after a ranking pass. Exact-prefix matches lead.
  """
  def search(query, user, org, opts \\ []) do
    needle = normalize(query)
    limit = Keyword.get(opts, :limit, 6)

    if needle == "" do
      []
    else
      user
      |> destinations(org)
      |> Enum.filter(&matches?(&1, needle))
      |> Enum.sort_by(&match_rank(&1, needle))
      |> Enum.take(limit)
    end
  end

  defp matches?(item, needle) do
    String.contains?(normalize(item.label), needle) or
      String.contains?(normalize(item[:section] || ""), needle)
  end

  # Title matches beat section matches, and a title that *starts* with what was
  # typed beats one that merely contains it ("Feeds" over "Content types" for
  # "ee"). Ties fall back to the label so the order is stable between renders.
  defp match_rank(item, needle) do
    label = normalize(item.label)

    rank =
      cond do
        String.starts_with?(label, needle) -> 0
        String.contains?(label, needle) -> 1
        true -> 2
      end

    {rank, label}
  end

  # `:nfd` + stripping combining marks so "Traducciones" is found by "traduc"
  # once a locale spells a label with an accent the admin skips.
  defp normalize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.trim()
  end

  defp author_items do
    multi_locale? = length(KilnCMS.I18n.locales()) > 1

    [
      %{
        key: :overview,
        label: gettext("Home"),
        path: ~p"/editor/overview",
        icon: "hero-squares-2x2"
      },
      %{key: :content, label: gettext("Content"), path: ~p"/editor", icon: "hero-document-text"},
      %{key: :media, label: gettext("Media"), path: ~p"/media", icon: "hero-photo"},
      %{key: :taxonomy, label: gettext("Taxonomy"), path: ~p"/editor/taxonomy", icon: "hero-tag"},
      %{key: :menus, label: gettext("Menus"), path: ~p"/editor/menus", icon: "hero-bars-3"},
      %{
        key: :calendar,
        label: gettext("Calendar"),
        path: ~p"/editor/calendar",
        icon: "hero-calendar-days"
      },
      %{
        key: :tasks,
        label: gettext("Tasks"),
        path: ~p"/editor/tasks",
        icon: "hero-clipboard-document-check"
      },
      # Content releases (#500) — editorial planning, so it sits with the author
      # group next to the calendar it plots onto, not with the admin tools. The
      # admin-only half (schedule/publish/roll back) is gated on the page.
      %{
        key: :releases,
        label: gettext("Releases"),
        path: ~p"/editor/releases",
        icon: "hero-rocket-launch"
      },
      multi_locale? &&
        %{
          key: :translations,
          label: gettext("Translations"),
          path: ~p"/editor/translations",
          icon: "hero-language"
        },
      %{
        key: :analytics,
        label: gettext("Analytics"),
        path: ~p"/editor/analytics",
        icon: "hero-chart-bar"
      },
      # Outbound broken links (#474). In the author group, not the admin one:
      # fixing a dead citation is editorial work. The opt-in switch on the page
      # is what admins own.
      %{
        key: :links,
        label: gettext("Links"),
        path: ~p"/editor/links",
        icon: "hero-link-slash"
      }
    ]
    |> Enum.filter(& &1)
  end

  defp settings_item,
    do: %{
      key: :settings,
      label: gettext("Settings"),
      path: ~p"/editor/settings",
      icon: "hero-cog-6-tooth"
    }

  defp configure_groups(:admin, platform_admin?) do
    [
      %{
        key: :content_model,
        label: gettext("Content model"),
        items: [
          %{
            key: :types,
            label: gettext("Content types"),
            path: ~p"/editor/types",
            icon: "hero-cube"
          },
          %{
            key: :fields,
            label: gettext("Fields"),
            path: ~p"/editor/fields",
            icon: "hero-adjustments-horizontal"
          },
          # Next to Content types, not down with Mail: what a feed carries is a
          # statement about content types, and the "has a public index" switch
          # this page defers to lives two items up (#719).
          %{key: :feeds, label: gettext("Feeds"), path: ~p"/editor/feeds", icon: "hero-rss"}
        ]
      },
      %{
        key: :capture,
        label: gettext("Capture"),
        items: [
          %{
            key: :forms,
            label: gettext("Forms"),
            path: ~p"/editor/forms",
            icon: "hero-clipboard-document-list"
          },
          %{
            key: :funnels,
            label: gettext("Funnels"),
            path: ~p"/editor/funnels",
            icon: "hero-funnel"
          },
          # Content experiments (#982). Beside Funnels: both are "measure what
          # this content does", and an experiment's goal can be a funnel.
          %{
            key: :experiments,
            label: gettext("Experiments"),
            path: ~p"/editor/experiments",
            icon: "hero-beaker"
          },
          # Per-site claim checking (#857). Called "Claim checking" rather than
          # "Compliance", which is already the Governance page's subject and the
          # name of the editor panel this switches on — an admin looking for one
          # should not have to guess which of two items owns it.
          %{
            key: :compliance,
            label: gettext("Claim checking"),
            path: ~p"/editor/compliance",
            icon: "hero-scale"
          }
        ]
      },
      %{
        key: :delivery,
        label: gettext("Delivery"),
        items: [
          %{
            key: :branding,
            label: gettext("Branding"),
            path: ~p"/editor/branding",
            icon: "hero-swatch"
          },
          %{
            key: :code_injection,
            label: gettext("Code injection"),
            path: ~p"/editor/code-injection",
            icon: "hero-code-bracket"
          },
          %{
            key: :redirects,
            label: gettext("Redirects"),
            path: ~p"/editor/redirects",
            icon: "hero-arrow-uturn-right"
          },
          %{key: :slugs, label: gettext("Slugs"), path: ~p"/editor/slugs", icon: "hero-link"},
          %{
            key: :social,
            label: gettext("Social"),
            path: ~p"/editor/social",
            icon: "hero-megaphone"
          },
          # With Social rather than with Mail: both are "the site reaching an
          # audience that isn't on it right now". Mail is the transport under
          # this, and transport is an operator's screen.
          %{
            key: :newsletter,
            label: gettext("Newsletter"),
            path: ~p"/editor/newsletter",
            icon: "hero-envelope-open"
          }
        ]
      },
      %{
        key: :integrations,
        label: gettext("Integrations"),
        items: [
          %{
            key: :webhooks,
            label: gettext("Webhooks"),
            path: ~p"/editor/webhooks",
            icon: "hero-bolt"
          },
          # ActivityPub federation (#967) — beside Webhooks: both are "what this
          # site tells other servers".
          %{
            key: :federation,
            label: gettext("Federation"),
            path: ~p"/editor/federation",
            icon: "hero-globe-alt"
          },
          %{
            key: :automation,
            label: gettext("Automation"),
            path: ~p"/editor/automation",
            icon: "hero-cpu-chip"
          }
        ]
      },
      %{
        key: :organization,
        label: gettext("Organization"),
        items: [
          %{
            key: :governance,
            label: gettext("Governance"),
            path: ~p"/editor/governance",
            icon: "hero-shield-check"
          },
          %{
            key: :trash,
            label: gettext("Trash"),
            path: ~p"/editor/trash",
            icon: "hero-trash"
          },
          settings_item()
        ]
      },
      # Operator-only, and drawn as such (#1319): every item here is
      # `platform: true`, so for anyone but a platform admin the section empties
      # and is dropped below. That is what makes the visual separation honest —
      # the band is never half day-to-day admin.
      %{
        key: :operations,
        label: gettext("Operations"),
        operator?: true,
        items: [
          %{
            platform: true,
            key: :team,
            label: gettext("Team"),
            path: ~p"/editor/team",
            icon: "hero-user-group"
          },
          %{
            platform: true,
            key: :billing,
            label: gettext("Billing"),
            path: ~p"/editor/billing",
            icon: "hero-credit-card"
          },
          %{
            platform: true,
            key: :mail,
            label: gettext("Mail"),
            path: ~p"/editor/mail",
            icon: "hero-envelope"
          },
          %{
            platform: true,
            key: :api_keys,
            label: gettext("API keys"),
            path: ~p"/editor/api-keys",
            icon: "hero-key"
          },
          %{
            platform: true,
            key: :backups,
            label: gettext("Backups"),
            path: ~p"/editor/backups",
            icon: "hero-archive-box"
          },
          %{
            platform: true,
            key: :system,
            label: gettext("System"),
            path: ~p"/editor/system",
            icon: "hero-server-stack"
          }
        ]
      }
    ]
    |> drop_hidden(platform_admin?)
  end

  defp configure_groups(_role, platform_admin?) do
    drop_hidden(
      [%{key: :configure, label: gettext("Configure"), items: [settings_item()]}],
      platform_admin?
    )
  end

  # Drop the platform-only items for anyone else, then any group left empty.
  defp drop_hidden(groups, platform_admin?) do
    groups
    |> Enum.map(&%{&1 | items: visible_items(&1.items, platform_admin?)})
    |> Enum.reject(&(&1.items == []))
  end

  defp visible_items(items, true = _platform_admin?), do: items
  defp visible_items(items, false), do: Enum.reject(items, &Map.get(&1, :platform, false))

  defp plugin_items(role) do
    for item <- Kiln.Plugins.nav_items(), plugin_visible?(item, role) do
      %{key: nil, label: item.label, path: item.path, icon: "hero-puzzle-piece"}
    end
  end

  defp plugin_visible?(%{role: :admin}, tier), do: tier == :admin
  defp plugin_visible?(%{role: :editor}, tier), do: tier in [:editor, :admin]
  defp plugin_visible?(_item, _tier), do: false
end
