defmodule KilnCMSWeb.ConsoleNav do
  @moduledoc """
  The console's navigation, as data (#1319).

  Three surfaces read this list, so they are the same list by construction:

    * the sidebar (`Layouts.console_nav/1`) draws it;
    * the Configure hub (`KilnCMSWeb.ConfigureLive`, `/editor/configure`) lists
      the admin screens with the one-line description each carries;
    * the ⌘K palette (`KilnCMSWeb.SearchPaletteLive`) searches it.

  A screen added here is reachable from all three the day it is added, and one
  an actor may not open is absent from all three. The alternative — a second,
  palette- or hub-shaped copy of the item list — is the shape that goes stale
  silently, and this codebase has been bitten by it before (the editor `@`
  roster, #1431).

  `nav/2` returns:

    * `:author` — the day-to-day editorial screens, drawn ungrouped at the top.
    * `:hub` — the Configure hub link, for an admin; `nil` for anyone else.
    * `:configure_groups` — the configuration screens, in collapsible sections.
      The last one is `operator?: true`: the instance-wide screens (Team,
      Billing, Mail, API keys, Backups, System) that `platform_admin_user?/1`
      gates, set apart because "restore last night's backup" and "fix a typo in
      a footer" are not the same job. Every item in it is `platform: true`, so
      for anyone else it empties and is dropped — the band is never half
      day-to-day admin.
    * `:plugin` — whatever plugins contributed, drawn last.

  Every configuration item carries a `:description` (what the screen is *for*,
  which a sidebar link cannot say) and `:keywords` (the words someone would
  type who does not know the screen's name — "rss", "dkim", "passkey").
  `rank/2` matches them, for both the hub's filter and the palette.

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
      hub: if(role == :admin, do: hub_item()),
      configure_groups: configure_groups(role, platform_admin?),
      plugin: plugin_items(role)
    }
  end

  @doc """
  Every console screen `user` may open on `org`, flattened for the ⌘K palette.

  Each grouped entry carries the `section` it sits under, so a result can say
  where the screen lives — "Backups · Operations" answers "am I about to touch
  the instance?" before the click, not after.
  """
  def destinations(user, org) do
    %{author: author, hub: hub, configure_groups: groups, plugin: plugin} = nav(user, org)

    grouped =
      Enum.flat_map(groups, fn group ->
        Enum.map(group.items, &Map.put(&1, :section, group.label))
      end)

    author ++ List.wrap(hub) ++ grouped ++ plugin
  end

  @doc """
  The destinations that answer `query`, best first (see `rank/2`).

  Plain substring matching, not the trigram search the content half of the
  palette runs: this list is ~30 items an admin half-remembers the name or the
  subject of, and an admin who types "back" wants Backups at the first
  keystroke, not after a ranking pass.
  """
  def search(query, user, org, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)

    user
    |> destinations(org)
    |> Enum.map(&{rank(&1, query), &1})
    |> Enum.reject(fn {rank, _item} -> is_nil(rank) end)
    |> Enum.sort_by(fn {rank, item} -> {rank, normalize(item.label)} end)
    |> Enum.take(limit)
    |> Enum.map(fn {_rank, item} -> item end)
  end

  @doc """
  Whether one screen answers `query`, and how well: `0`–`2`, lower is better,
  or `nil` for no match. A blank query matches nothing.

    * `0` — the name starts with the query;
    * `1` — the name contains it;
    * `2` — its section, description or a keyword contains it.

  So the screen called Mail leads for "mail", ahead of Newsletter, which only
  carries "email" as a keyword. The hub asks only whether the answer is `nil`
  (it keeps the map's own order); the palette sorts by it. Both asking this one
  function is the point: a screen the hub's filter finds and the palette does
  not is the kind of divergence nobody notices until they are looking for it.

  Case- and accent-insensitive, so "Traducciones" is found by "traduc" once a
  locale spells a label with an accent the admin skips.
  """
  def rank(item, query) do
    needle = normalize(query)
    label = normalize(item.label)

    context = [
      Map.get(item, :section, ""),
      Map.get(item, :description, "") | Map.get(item, :keywords, [])
    ]

    cond do
      needle == "" -> nil
      String.starts_with?(label, needle) -> 0
      String.contains?(label, needle) -> 1
      Enum.any?(context, &String.contains?(normalize(&1), needle)) -> 2
      true -> nil
    end
  end

  defp normalize(nil), do: ""

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

  # The console had twenty-odd configuration screens and no screen that WAS
  # configuration (#1319). The hub is that screen; it holds no settings itself.
  defp hub_item,
    do: %{
      key: :configure,
      label: gettext("Configure"),
      path: ~p"/editor/configure",
      icon: "hero-cog-6-tooth",
      description: gettext("Every settings screen, and what each one is for."),
      keywords: ["settings", "preferences", "admin", "options"]
    }

  # Deliberately labelled for the person, not the site: the complaint behind
  # #1319 was that the one screen called "Settings" is per-user, so site
  # configuration looked like it had no home. The hub is that home; this is
  # what is left, and it says whose it is.
  defp account_group,
    do: %{
      key: :account,
      label: gettext("Account"),
      items: [
        %{
          key: :settings,
          label: gettext("Your settings"),
          path: ~p"/editor/settings",
          icon: "hero-user-circle",
          description: gettext("Your profile, password, two-factor, passkeys and notifications."),
          keywords: ["profile", "password", "2fa", "totp", "passkey", "notifications", "me"]
        }
      ]
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
            icon: "hero-cube",
            description: gettext("New types of document, without a code change."),
            keywords: ["type", "schema", "structure", "collection"]
          },
          %{
            key: :fields,
            label: gettext("Fields"),
            path: ~p"/editor/fields",
            icon: "hero-adjustments-horizontal",
            description: gettext("Typed custom fields on a content type."),
            keywords: ["custom fields", "metadata", "schema", "attribute"]
          },
          # Next to Content types, not down with Mail: what a feed carries is a
          # statement about content types, and the "has a public index" switch
          # this page defers to lives two items up (#719).
          %{
            key: :feeds,
            label: gettext("Feeds"),
            path: ~p"/editor/feeds",
            icon: "hero-rss",
            description: gettext("Which types syndicate, and whether in full."),
            keywords: ["rss", "atom", "syndication", "json feed"]
          }
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
            icon: "hero-clipboard-document-list",
            description: gettext("Public forms and the submissions they collect."),
            keywords: ["submission", "contact", "survey", "input"]
          },
          %{
            key: :funnels,
            label: gettext("Funnels"),
            path: ~p"/editor/funnels",
            icon: "hero-funnel",
            description: gettext("Ordered content steps, and where readers drop out."),
            keywords: ["conversion", "steps", "journey", "drop-off"]
          },
          # Content experiments (#982). Beside Funnels: both are "measure what
          # this content does", and an experiment's goal can be a funnel.
          %{
            key: :experiments,
            label: gettext("Experiments"),
            path: ~p"/editor/experiments",
            icon: "hero-beaker",
            description: gettext("A/B a headline or a block, and promote the winner."),
            keywords: ["a/b", "variant", "test", "split"]
          },
          # Per-site claim checking (#857). Called "Claim checking" rather than
          # "Compliance", which is already the Governance page's subject and the
          # name of the editor panel this switches on — an admin looking for one
          # should not have to guess which of two items owns it.
          %{
            key: :compliance,
            label: gettext("Claim checking"),
            path: ~p"/editor/compliance",
            icon: "hero-scale",
            description: gettext("The claims vocabulary the editor panel checks against."),
            keywords: ["claims", "compliance", "regulated", "vocabulary", "publish gate"]
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
            icon: "hero-swatch",
            description: gettext("Name, logo, colours and the public theme."),
            keywords: ["theme", "logo", "colours", "colors", "favicon", "appearance"]
          },
          %{
            key: :code_injection,
            label: gettext("Code injection"),
            path: ~p"/editor/code-injection",
            icon: "hero-code-bracket",
            description: gettext("Custom CSS, scripts and the origins they may reach."),
            keywords: ["css", "javascript", "script", "analytics", "csp", "head", "footer"]
          },
          %{
            key: :redirects,
            label: gettext("Redirects"),
            path: ~p"/editor/redirects",
            icon: "hero-arrow-uturn-right",
            description: gettext("Where moved URLs point, and what visitors asked for in vain."),
            keywords: ["301", "404", "moved", "missing", "url"]
          },
          %{
            key: :slugs,
            label: gettext("Slugs"),
            path: ~p"/editor/slugs",
            icon: "hero-link",
            description: gettext("How URLs are built, and bulk regeneration."),
            keywords: ["url", "path", "permalink", "pathauto"]
          },
          %{
            key: :social,
            label: gettext("Social"),
            path: ~p"/editor/social",
            icon: "hero-megaphone",
            description: gettext("Bluesky and Mastodon accounts this site announces from."),
            keywords: ["bluesky", "mastodon", "announce", "sharing"]
          },
          # With Social rather than with Mail: both are "the site reaching an
          # audience that isn't on it right now". Mail is the transport under
          # this, and transport is an operator's screen.
          %{
            key: :newsletter,
            label: gettext("Newsletter"),
            path: ~p"/editor/newsletter",
            icon: "hero-envelope-open",
            description: gettext("Send a published post to your subscribers."),
            keywords: ["email", "subscribers", "broadcast", "campaign"]
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
            icon: "hero-bolt",
            description: gettext("Signed POSTs to other services when content changes."),
            keywords: ["http", "callback", "signature", "endpoint", "slack"]
          },
          # ActivityPub federation (#967) — beside Webhooks: both are "what this
          # site tells other servers".
          %{
            key: :federation,
            label: gettext("Federation"),
            path: ~p"/editor/federation",
            icon: "hero-globe-alt",
            description: gettext("This site as an ActivityPub actor, and its followers."),
            keywords: ["activitypub", "fediverse", "mastodon", "followers", "actor"]
          },
          %{
            key: :automation,
            label: gettext("Automation"),
            path: ~p"/editor/automation",
            icon: "hero-cpu-chip",
            description: gettext("When something is published, do this."),
            keywords: ["rules", "trigger", "reaction", "workflow", "if this then that"]
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
            icon: "hero-shield-check",
            description: gettext("Content freshness, provenance and the audit record."),
            keywords: ["audit", "provenance", "witness", "freshness", "review cadence"]
          },
          %{
            key: :trash,
            label: gettext("Trash"),
            path: ~p"/editor/trash",
            icon: "hero-trash",
            description: gettext("Deleted content, restorable until it is purged."),
            keywords: ["deleted", "restore", "recycle", "archive"]
          }
        ]
      },
      # Above the operator band, not below it: anything after the band's rule
      # reads as part of the band.
      account_group(),
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
            icon: "hero-user-group",
            description: gettext("Who can author what, and under which role."),
            keywords: ["users", "members", "roles", "permissions", "rbac", "invite"]
          },
          %{
            platform: true,
            key: :billing,
            label: gettext("Billing"),
            path: ~p"/editor/billing",
            icon: "hero-credit-card",
            description: gettext("The payment provider, and the tiers readers can buy."),
            keywords: ["payments", "stripe", "memberships", "tiers", "subscriptions"]
          },
          %{
            platform: true,
            key: :mail,
            label: gettext("Mail"),
            path: ~p"/editor/mail",
            icon: "hero-envelope",
            description: gettext("How this instance sends email, and its DNS records."),
            keywords: ["smtp", "dkim", "spf", "dmarc", "delivery", "sending"]
          },
          %{
            platform: true,
            key: :api_keys,
            label: gettext("API keys"),
            path: ~p"/editor/api-keys",
            icon: "hero-key",
            description: gettext("Headless access to the delivery and authoring APIs."),
            keywords: ["token", "headless", "mcp", "graphql", "json:api", "integration"]
          },
          %{
            platform: true,
            key: :backups,
            label: gettext("Backups"),
            path: ~p"/editor/backups",
            icon: "hero-archive-box",
            description:
              gettext("The database and uploaded media, and when they were last saved."),
            keywords: ["restore", "snapshot", "dump", "disaster recovery"]
          },
          %{
            platform: true,
            key: :system,
            label: gettext("System"),
            path: ~p"/editor/system",
            icon: "hero-server-stack",
            description: gettext("This instance's version, plugins and health."),
            keywords: ["version", "update", "upgrade", "plugins", "health", "status"]
          }
        ]
      }
    ]
    |> drop_hidden(platform_admin?)
  end

  # A non-admin gets their own settings and nothing else; the site-level
  # screens all gate on `:admin` at the router.
  defp configure_groups(_role, platform_admin?),
    do: drop_hidden([account_group()], platform_admin?)

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
