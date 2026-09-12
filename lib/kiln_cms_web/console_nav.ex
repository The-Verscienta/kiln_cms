defmodule KilnCMSWeb.ConsoleNav do
  @moduledoc """
  The console's navigation map (#1319): one list of every authoring and
  configuration screen, with the grouping, the role gate, and the one-line
  description each screen is introduced by.

  Three surfaces read it and they must not drift apart:

    * the sidebar (`KilnCMSWeb.Layouts`'s private `console_nav/1`),
    * the Configure hub (`KilnCMSWeb.ConfigureLive`, `/editor/configure`),
    * the ⌘K palette (`KilnCMSWeb.SearchPaletteLive`), which searches settings
      screens by name alongside content.

  Before this module the sidebar *was* the map — a literal in a markup function
  — so the hub and the palette would each have had to restate it, and the third
  copy is the one that goes stale.

  ## Two axes, not one

  A group carries a `:scope` as well as a label:

    * `:site` — what a site's admin changes about *their* site: branding,
      content model, capture, integrations.
    * `:instance` — what an operator changes about *the deployment*: team and
      billing, mail transport, backups, the build itself. Mostly, but not
      always, `platform: true` as well.
    * `:user` — the signed-in person's own settings, which are nobody else's.

  Scope is what the sidebar and the hub separate on. It is presentation, not
  authorization: every page behind these links re-authorizes on its own, and
  `platform: true` (which *is* a gate, mirrored from
  `KilnCMSWeb.LiveUserAuth.platform_admin_user?/1`) is a separate field for
  exactly that reason.

  ## Keys are not labels

  Every group carries a locale-independent `:key` because the client persists
  which groups are collapsed under it. A label is translated and would give a
  reader a different set of collapsed groups per locale.
  """

  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  @type item :: %{
          required(:key) => atom() | nil,
          required(:label) => String.t(),
          required(:path) => String.t(),
          required(:icon) => String.t(),
          optional(:description) => String.t(),
          optional(:keywords) => [String.t()],
          optional(:platform) => boolean()
        }

  @type group :: %{
          key: String.t(),
          label: String.t(),
          scope: :site | :instance | :user,
          items: [item()]
        }

  @doc """
  The author group — the day-to-day editorial screens, shown to every tier.

  `multi_locale?` drops Translations on a single-locale deployment, where the
  screen has nothing to show.
  """
  @spec author_items(keyword()) :: [item()]
  def author_items(opts \\ []) do
    multi_locale? = Keyword.get(opts, :multi_locale?, length(KilnCMS.I18n.locales()) > 1)

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

  @doc """
  The Configure groups visible to `role` (the effective tier on the current
  site) and `platform_admin?` (the global gate the instance-wide consoles
  themselves apply).

  Groups left empty by the `platform: true` filter are dropped, so a per-org
  admin on a deployment they do not operate never sees a heading with nothing
  under it.
  """
  @spec configure_groups(atom(), boolean()) :: [group()]
  def configure_groups(role, platform_admin?) do
    role
    |> all_configure_groups()
    |> Enum.map(&%{&1 | items: visible_items(&1.items, platform_admin?)})
    |> Enum.reject(&(&1.items == []))
  end

  # A non-admin gets their own settings and nothing else; the site-level
  # screens all gate on `:admin` at the router.
  defp all_configure_groups(role) when role != :admin, do: [account_group()]

  defp all_configure_groups(_admin) do
    [
      %{
        key: "site",
        label: gettext("Site"),
        scope: :site,
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
            key: :social,
            label: gettext("Social"),
            path: ~p"/editor/social",
            icon: "hero-megaphone",
            description: gettext("Bluesky and Mastodon accounts this site announces from."),
            keywords: ["bluesky", "mastodon", "announce", "sharing"]
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
            key: :redirects,
            label: gettext("Redirects"),
            path: ~p"/editor/redirects",
            icon: "hero-arrow-uturn-right",
            description: gettext("Where moved URLs point, and what visitors asked for in vain."),
            keywords: ["301", "404", "moved", "missing", "url"]
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
      %{
        key: "model",
        label: gettext("Content model"),
        scope: :site,
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
          # Next to Content types, not down with Mail: what a feed carries
          # is a statement about content types, and the "has a public
          # index" switch this page defers to lives two items up (#719).
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
        key: "capture",
        label: gettext("Capture"),
        scope: :site,
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
          # Content experiments (#982). Beside Funnels: both are "measure
          # what this content does", and an experiment's goal can be a funnel.
          %{
            key: :experiments,
            label: gettext("Experiments"),
            path: ~p"/editor/experiments",
            icon: "hero-beaker",
            description: gettext("A/B a headline or a block, and promote the winner."),
            keywords: ["a/b", "variant", "test", "split"]
          },
          # Per-site claim checking (#857). Called "Claim checking" rather
          # than "Compliance", which is already the Governance page's
          # subject and the name of the editor panel this switches on — an
          # admin looking for one should not have to guess which of two
          # items owns it.
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
        key: "integrations",
        label: gettext("Integrations"),
        scope: :site,
        items: [
          %{
            key: :webhooks,
            label: gettext("Webhooks"),
            path: ~p"/editor/webhooks",
            icon: "hero-bolt",
            description: gettext("Signed POSTs to other services when content changes."),
            keywords: ["http", "callback", "signature", "endpoint", "slack"]
          },
          %{
            key: :automation,
            label: gettext("Automation"),
            path: ~p"/editor/automation",
            icon: "hero-cpu-chip",
            description: gettext("When something is published, do this."),
            keywords: ["rules", "trigger", "reaction", "workflow", "if this then that"]
          },
          # ActivityPub federation (#967) — beside Webhooks: both are "what
          # this site tells other servers", and both are admin-only.
          %{
            key: :federation,
            label: gettext("Federation"),
            path: ~p"/editor/federation",
            icon: "hero-globe-alt",
            description: gettext("This site as an ActivityPub actor, and its followers."),
            keywords: ["activitypub", "fediverse", "mastodon", "followers", "actor"]
          },
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
        key: "operations",
        label: gettext("Operations"),
        scope: :instance,
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
            key: :governance,
            label: gettext("Governance"),
            path: ~p"/editor/governance",
            icon: "hero-shield-check",
            description: gettext("Content freshness, provenance and the audit record."),
            keywords: ["audit", "provenance", "witness", "freshness", "review cadence"]
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
            key: :mail,
            label: gettext("Mail"),
            path: ~p"/editor/mail",
            icon: "hero-envelope",
            description: gettext("How this instance sends email, and its DNS records."),
            keywords: ["smtp", "dkim", "spf", "dmarc", "delivery", "sending"]
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
            key: :billing,
            label: gettext("Billing"),
            path: ~p"/editor/billing",
            icon: "hero-credit-card",
            description: gettext("The payment provider, and the tiers readers can buy."),
            keywords: ["payments", "stripe", "memberships", "tiers", "subscriptions"]
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
      },
      account_group()
    ]
  end

  # Deliberately labelled for the person, not the site: the complaint behind
  # #1319 was that the one screen called "Settings" is per-user, so site
  # configuration looked like it had no home. The hub is that home; this is
  # what is left, and it says whose it is.
  defp account_group do
    %{
      key: "account",
      label: gettext("Account"),
      scope: :user,
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
  end

  @doc """
  Drops the `platform: true` items for anyone who is not a platform admin.

  The instance-wide consoles — Team, Billing, System, Mail, Backups, API keys —
  gate their pages on the GLOBAL role (`LiveUserAuth.platform_admin_user?/1`,
  #419/#1160), not on the per-org tier. A per-org admin passes `role == :admin`
  and would be shown links those pages only bounce, so the links ask the same
  predicate the pages do.
  """
  @spec visible_items([item()], boolean()) :: [item()]
  def visible_items(items, true = _platform_admin?), do: items
  def visible_items(items, false), do: Enum.reject(items, &Map.get(&1, :platform, false))

  @doc """
  Every configuration screen the viewer may reach, flattened, each item tagged
  with the `:group` label, `:group_key` and `:scope` it came from.

  This is what the hub lists and the palette searches.
  """
  @spec settings_items(atom(), boolean()) :: [map()]
  def settings_items(role, platform_admin?) do
    for group <- configure_groups(role, platform_admin?),
        item <- group.items,
        do: Map.merge(item, %{group: group.label, group_key: group.key, scope: group.scope})
  end

  @doc """
  Settings screens whose name, group or keywords match `query`.

  A plain substring match on a list of a couple of dozen rows — deliberately
  not `KilnCMS.Search`, which indexes documents. Ranked so a name match beats a
  keyword match, and a name that *starts* with the query beats one that merely
  contains it: "mail" is the whole name of one screen and a keyword on
  Newsletter, and the screen called Mail is the one that should lead.

  Returns `[]` for a blank query rather than the whole list: the palette shows
  settings only once someone has typed.
  """
  @spec search(String.t(), atom(), boolean(), keyword()) :: [map()]
  def search(query, role, platform_admin?, opts \\ []) do
    limit = Keyword.get(opts, :limit, 6)
    needle = normalize(query)

    if needle == "" do
      []
    else
      role
      |> settings_items(platform_admin?)
      |> Enum.map(&{rank(&1, &1.group, query), &1})
      |> Enum.reject(fn {rank, _item} -> rank == nil end)
      |> Enum.sort_by(fn {rank, item} -> {rank, item.label} end)
      |> Enum.take(limit)
      |> Enum.map(fn {_rank, item} -> item end)
    end
  end

  @doc """
  Whether one settings screen answers `query`, and how well.

  `0`/`1`/`2` rank a hit (lower is better); `nil` is no hit. The hub
  (`KilnCMSWeb.ConfigureLive`) asks only whether the answer is `nil`, since it
  keeps the map's own order; the palette sorts by it. Both ask the same
  question, which is the point of it living here — a screen that the hub's
  filter finds and the palette does not is the kind of divergence nobody
  notices until they are looking for the screen.

  `group_label` is passed separately so the hub can ask before it has flattened
  its groups.
  """
  @spec rank(map(), String.t(), String.t()) :: 0 | 1 | 2 | nil
  def rank(item, group_label, query) do
    needle = normalize(query)
    label = normalize(item.label)

    haystack =
      [group_label, Map.get(item, :description, "") | Map.get(item, :keywords, [])]

    cond do
      needle == "" -> nil
      String.starts_with?(label, needle) -> 0
      String.contains?(label, needle) -> 1
      Enum.any?(haystack, &String.contains?(normalize(&1), needle)) -> 2
      true -> nil
    end
  end

  defp normalize(nil), do: ""

  defp normalize(text) when is_binary(text) do
    text |> String.trim() |> String.downcase()
  end
end
