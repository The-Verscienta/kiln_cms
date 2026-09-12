defmodule KilnCMSWeb.ConsoleNavTest do
  @moduledoc """
  The console's navigation map (#1319).

  Three surfaces render from this one list — the sidebar, the Configure hub and
  the ⌘K palette — so the properties worth pinning are the ones a reader of any
  single call site can't check: that the role gate is applied on the way out
  (not left to each caller), that every path is a route the router actually has,
  and that the ranking makes the obvious query land on the obvious screen.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ConsoleNav

  defp items(groups), do: Enum.flat_map(groups, & &1.items)
  defp keys(groups), do: groups |> items() |> Enum.map(& &1.key)
  defp group_keys(groups), do: Enum.map(groups, & &1.key)

  describe "configure_groups/2" do
    test "a non-admin gets their own settings and no site configuration at all" do
      for role <- [:viewer, :editor] do
        groups = ConsoleNav.configure_groups(role, false)

        assert group_keys(groups) == ["account"]
        assert keys(groups) == [:settings]
      end
    end

    test "an org admin who does not operate the deployment sees no platform screens" do
      groups = ConsoleNav.configure_groups(:admin, false)
      shown = keys(groups)

      # The instance-wide consoles gate on the GLOBAL role, so linking them to a
      # per-org admin would only produce a bounce (#419/#1160).
      for platform_only <- [:team, :billing, :api_keys, :mail, :backups, :system] do
        refute platform_only in shown
      end

      # What is left is still theirs to change.
      for site_level <- [:branding, :types, :forms, :webhooks, :governance] do
        assert site_level in shown
      end
    end

    test "a platform admin sees the operator screens, under an :instance-scoped group" do
      groups = ConsoleNav.configure_groups(:admin, true)
      assert :backups in keys(groups)

      instance = Enum.filter(groups, &(&1.scope == :instance))
      assert group_keys(instance) == ["operations"]

      # Every platform-gated item is in that group and nowhere else — the seam
      # the sidebar and the hub draw is only honest if it holds.
      platform_items =
        groups |> items() |> Enum.filter(&Map.get(&1, :platform, false)) |> Enum.map(& &1.key)

      assert Enum.sort(platform_items) ==
               Enum.sort([:team, :billing, :api_keys, :mail, :backups, :system])

      assert platform_items -- Enum.map(items(instance), & &1.key) == []
    end

    test "a group emptied by the platform filter is dropped, not left as a bare heading" do
      groups = ConsoleNav.configure_groups(:admin, false)

      refute Enum.any?(groups, &(&1.items == []))
      # Operations keeps Governance, which is not platform-gated.
      assert "operations" in group_keys(groups)
      assert keys(groups) |> Enum.filter(&(&1 == :governance)) == [:governance]
    end

    test "keys are unique, and group keys are the locale-independent kind" do
      groups = ConsoleNav.configure_groups(:admin, true)

      item_keys = keys(groups)
      assert Enum.uniq(item_keys) == item_keys

      # The client persists which groups are collapsed under these, and the
      # pre-paint restore in root.html.heex filters them to /^[a-z]+$/ before
      # they reach a selector — a key outside that set would silently never
      # collapse.
      for key <- group_keys(groups) do
        assert key =~ ~r/^[a-z]+$/, "group key #{inspect(key)} would be filtered out client-side"
      end
    end

    test "every item carries what all three surfaces need" do
      for item <- items(ConsoleNav.configure_groups(:admin, true)) do
        assert is_atom(item.key)
        assert is_binary(item.label) and item.label != ""
        assert is_binary(item.icon) and String.starts_with?(item.icon, "hero-")
        assert is_binary(item.description) and item.description != ""
        assert is_list(item.keywords)
      end
    end
  end

  test "every path in the map is a route the router actually serves" do
    routes = MapSet.new(KilnCMSWeb.Router.__routes__(), & &1.path)

    paths =
      ConsoleNav.author_items(multi_locale?: true) ++
        items(ConsoleNav.configure_groups(:admin, true))

    for %{path: path, label: label} <- paths do
      assert MapSet.member?(routes, path), "#{label} links to #{path}, which is not a route"
    end
  end

  describe "author_items/1" do
    test "Translations appears only where there is more than one locale" do
      assert :translations in Enum.map(ConsoleNav.author_items(multi_locale?: true), & &1.key)
      refute :translations in Enum.map(ConsoleNav.author_items(multi_locale?: false), & &1.key)
    end
  end

  describe "search/4" do
    defp found(query, role \\ :admin, platform_admin? \\ true),
      do: query |> ConsoleNav.search(role, platform_admin?) |> Enum.map(& &1.key)

    test "a blank query matches nothing — the palette lists settings only once you type" do
      assert ConsoleNav.search("", :admin, true) == []
      assert ConsoleNav.search("   ", :admin, true) == []
    end

    test "a name match beats a keyword match" do
      # "mail" is the whole of one screen's name, and a keyword ("email") on
      # Newsletter. The screen called Mail is the one that should lead.
      assert found("mail") == [:mail, :newsletter]
    end

    test "a name that starts with the query beats one that merely contains it" do
      # Slugs, Social and System start with "s"; Feeds, Webhooks and the rest
      # only contain one. The three prefixes come first, in name order.
      assert Enum.take(found("s"), 3) == [:slugs, :social, :system]
    end

    test "the words someone would actually type find the screen that owns them" do
      # The complaint in #1319: the palette was content-only, so none of these
      # led anywhere.
      assert :feeds in found("rss")
      assert :billing in found("stripe")
      assert :settings in found("passkey")
      assert :team in found("permissions")
      assert :code_injection in found("css")
      assert :redirects in found("301")
      assert :mail in found("dkim")
    end

    test "matching is case- and whitespace-insensitive" do
      assert found("  RSS  ") == found("rss")
    end

    test "it never offers a screen the viewer would be bounced from" do
      # An editor: their own settings are reachable, the site's are not.
      assert found("passkey", :editor, false) == [:settings]
      assert found("rss", :editor, false) == []

      # An org admin who does not operate the deployment.
      assert found("dkim", :admin, false) == []
      assert :feeds in found("rss", :admin, false)
    end

    test "results are capped" do
      # "s" matches nearly everything; the palette shows a handful.
      assert length(ConsoleNav.search("s", :admin, true)) <= 6
      assert length(ConsoleNav.search("s", :admin, true, limit: 2)) == 2
    end

    test "a match carries the group it came from, so a result can say where it lives" do
      [feeds] = ConsoleNav.search("feeds", :admin, true)

      assert feeds.group_key == "model"
      assert feeds.scope == :site
      assert is_binary(feeds.group)
    end
  end
end
