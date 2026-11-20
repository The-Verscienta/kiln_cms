defmodule KilnCMSWeb.PluginHealthJSONTest do
  @moduledoc """
  `KilnCMSWeb.PluginHealthJSON` (#2571), from literal reports: the exact keys,
  every integrity and abandonment variant, what is never emitted (checksums,
  retirement messages, notice titles and ranges), and the cold-cache body.
  """
  use ExUnit.Case, async: true

  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.PluginStatus
  alias Kiln.Plugins.Health.Report
  alias KilnCMSWeb.PluginHealthJSON

  @locked "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"
  @registry "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30685"

  @top ~w(checked_at counts notices plugins state version)
  @plugin ~w(abandonment id integrity latest_version name notices overall package source version)
  @counts ~w(fail not_applicable ok unknown unverifiable warn)

  defp status(overrides) do
    struct!(
      %PluginStatus{
        plugin: MyApp.SomePlugin,
        name: "some_plugin",
        source: :hex,
        package: "some_plugin",
        version: "1.2.0",
        latest_version: "1.3.0",
        sdk_requirement: "~> 1.4",
        outer_checksum: @locked,
        git_ref: "deadbeefcafe",
        integrity: :ok,
        advisories: {:ok, []},
        abandonment: [],
        abandonment_known?: true,
        overall: :ok
      },
      overrides
    )
  end

  defp report(plugins, overrides \\ []) do
    struct!(
      %Report{
        plugins: plugins,
        checked_at: ~U[2026-11-19 09:00:00.123456Z],
        state: :fresh,
        notices: :ok
      },
      overrides
    )
  end

  defp show(report), do: PluginHealthJSON.show(%{report: report})

  defp only(plugin_overrides), do: show(report([status(plugin_overrides)]))["plugins"] |> hd()

  test "has exactly the documented keys" do
    body = show(report([status(%{})]))

    assert body |> Map.keys() |> Enum.sort() == @top
    assert body["version"] == 1 and PluginHealthJSON.version() == 1
    assert body["state"] == "fresh"
    assert body["notices"] == "ok"
    assert body["checked_at"] == "2026-11-19T09:00:00Z"
    assert body["counts"] |> Map.keys() |> Enum.sort() == @counts

    [plugin] = body["plugins"]
    assert plugin |> Map.keys() |> Enum.sort() == @plugin

    assert %{
             "id" => "MyApp.SomePlugin",
             "name" => "some_plugin",
             "source" => "hex",
             "package" => "some_plugin",
             "version" => "1.2.0",
             "latest_version" => "1.3.0",
             "overall" => "ok",
             "integrity" => %{"status" => "ok", "reason" => nil},
             "notices" => %{"complete" => true, "items" => []},
             "abandonment" => %{"known" => true, "reasons" => []}
           } = plugin

    assert {:ok, _json} = Jason.encode(body)
  end

  test "never carries the checksums, the git ref, or the declared requirement" do
    body =
      show(
        report([
          status(%{integrity: {:mismatch, %{locked: @locked, registry: @registry}}}),
          status(%{plugin: MyApp.Git, source: :git, git_ref: "0123456789abcdef"})
        ])
      )

    json = Jason.encode!(body)

    for secret <- [@locked, @registry, "deadbeefcafe", "0123456789abcdef", "~> 1.4"],
        do: refute(json =~ secret)

    assert Enum.any?(
             body["plugins"],
             &(&1["integrity"] == %{"status" => "mismatch", "reason" => nil})
           )
  end

  test "every integrity variant" do
    for {integrity, expected} <- [
          {:ok, %{"status" => "ok", "reason" => nil}},
          {{:mismatch, %{locked: @locked, registry: @registry}},
           %{"status" => "mismatch", "reason" => nil}},
          {:not_found, %{"status" => "not_found", "reason" => nil}},
          {{:unverifiable, :git}, %{"status" => "unverifiable", "reason" => "git"}},
          {{:unverifiable, :path}, %{"status" => "unverifiable", "reason" => "path"}},
          {{:unverifiable, :private_repo},
           %{"status" => "unverifiable", "reason" => "private_repo"}},
          {{:unverifiable, :no_checksum},
           %{"status" => "unverifiable", "reason" => "no_checksum"}},
          {{:unverifiable, :unknown_source},
           %{"status" => "unverifiable", "reason" => "unknown_source"}},
          {:not_applicable, %{"status" => "not_applicable", "reason" => nil}},
          {:unknown, %{"status" => "unknown", "reason" => nil}},
          {:disabled, %{"status" => "disabled", "reason" => nil}}
        ] do
      assert only(%{integrity: integrity})["integrity"] == expected
    end
  end

  test "every abandonment reason carries all five keys, and no retirement message" do
    reasons =
      only(%{
        abandonment: [
          {:retired, :security, "Use other_plugin; contact ops@example.com"},
          {:retired, :something_new, nil},
          {:stale, ~U[2024-01-02 03:04:05.678Z]},
          {:sdk_unsupported, "~> 2.0", "1.5.0"},
          {:sdk_requirement_invalid, "not a requirement"}
        ]
      })["abandonment"]["reasons"]

    keys = ~w(bundled kind last_release_at requirement retirement)
    for reason <- reasons, do: assert(reason |> Map.keys() |> Enum.sort() == keys)

    assert reasons == [
             %{
               "kind" => "retired",
               "retirement" => "security",
               "last_release_at" => nil,
               "requirement" => nil,
               "bundled" => nil
             },
             %{
               "kind" => "retired",
               "retirement" => "other",
               "last_release_at" => nil,
               "requirement" => nil,
               "bundled" => nil
             },
             %{
               "kind" => "stale",
               "retirement" => nil,
               "last_release_at" => "2024-01-02T03:04:05Z",
               "requirement" => nil,
               "bundled" => nil
             },
             %{
               "kind" => "sdk_unsupported",
               "retirement" => nil,
               "last_release_at" => nil,
               "requirement" => "~> 2.0",
               "bundled" => "1.5.0"
             },
             %{
               "kind" => "sdk_requirement_invalid",
               "retirement" => nil,
               "last_release_at" => nil,
               "requirement" => "not a requirement",
               "bundled" => nil
             }
           ]

    for retirement <- ~w(security deprecated invalid renamed other)a do
      [reason] = only(%{abandonment: [{:retired, retirement, "msg"}]})["abandonment"]["reasons"]
      assert reason["retirement"] == Atom.to_string(retirement)
    end

    refute Jason.encode!(
             show(report([status(%{abandonment: [{:retired, :security, "ops@example.com"}]})]))
           ) =~
             "ops@example.com"

    assert only(%{abandonment_known?: false})["abandonment"]["known"] == false
  end

  test "notices: what was found, whether it is complete, and nothing for a person to read" do
    notice = %Notice{
      id: "GHSA-aaaa-bbbb-cccc",
      aliases: ["CVE-2026-0001"],
      title: "Remote code execution in some_plugin",
      affected: ">= 1.0.0, < 1.3.0",
      patched: "1.3.0",
      packages: ["some_plugin"],
      severity: :high,
      url: "https://kilncms.dev/security/GHSA-aaaa-bbbb-cccc",
      source: :kiln
    }

    plugin = only(%{advisories: {:ok, [notice]}})

    assert plugin["notices"] == %{
             "complete" => true,
             "items" => [
               %{
                 "id" => "GHSA-aaaa-bbbb-cccc",
                 "aliases" => ["CVE-2026-0001"],
                 "severity" => "high",
                 "source" => "kiln",
                 "url" => "https://kilncms.dev/security/GHSA-aaaa-bbbb-cccc"
               }
             ]
           }

    json = Jason.encode!(plugin)
    refute json =~ "Remote code execution"
    refute json =~ ">= 1.0.0"
    refute json =~ "\"patched\""

    assert %{"complete" => false, "items" => [_]} =
             only(%{advisories: {:unknown, [notice]}})["notices"]

    assert %{"complete" => false, "items" => []} = only(%{advisories: {:unknown, []}})["notices"]

    for bad <- [
          "javascript:alert(1)",
          "ftp://example.com/x",
          "/relative",
          "https://",
          nil,
          "https://example.com/" <> <<0xFF>>
        ] do
      [item] = only(%{advisories: {:ok, [%{notice | url: bad}]}})["notices"]["items"]
      assert item["url"] == nil, "expected #{inspect(bad)} to be dropped"
    end

    [item] =
      only(%{advisories: {:ok, [%{notice | url: "http://example.com/a"}]}})["notices"]["items"]

    assert item["url"] == "http://example.com/a"
  end

  test "a cold cache is not_checked, never a clean bill" do
    body = show(nil)

    assert body == %{
             "version" => 1,
             "state" => "not_checked",
             "checked_at" => nil,
             "notices" => nil,
             "counts" => Map.new(@counts, &{&1, 0}),
             "plugins" => []
           }

    assert {:ok, _json} = Jason.encode(body)
  end

  test "a disabled check carries no checked_at" do
    body =
      show(
        report([status(%{integrity: :disabled, overall: :unknown})],
          state: :disabled,
          notices: :disabled,
          checked_at: nil
        )
      )

    assert %{"state" => "disabled", "notices" => "disabled", "checked_at" => nil} = body
  end

  test "replaces invalid UTF-8 in every string" do
    plugin =
      only(%{
        name: "bad" <> <<0xFF>>,
        package: "pkg" <> <<0xFE>>,
        version: "1.0" <> <<0xFF>>,
        latest_version: "2.0" <> <<0xFF>>,
        advisories:
          {:ok, [%Notice{id: "id" <> <<0xFF>>, aliases: ["a" <> <<0xFF>>], source: :hex}]},
        abandonment: [{:sdk_unsupported, "~> 2" <> <<0xFF>>, "1" <> <<0xFF>>}]
      })

    assert plugin["name"] == "bad�"
    assert plugin["package"] == "pkg�"
    assert plugin["version"] == "1.0�"
    assert plugin["latest_version"] == "2.0�"

    assert [%{"id" => "id�", "aliases" => ["a�"], "severity" => "unknown"}] =
             plugin["notices"]["items"]

    assert [%{"requirement" => "~> 2�", "bundled" => "1�"}] = plugin["abandonment"]["reasons"]
    assert {:ok, _json} = Jason.encode(plugin)
  end

  test "keys plugins by a unique id, sorted by name then id, and counts every overall" do
    body =
      show(
        report([
          status(%{plugin: Zeta.Plugin, name: "same", overall: :warn}),
          status(%{plugin: Alpha.Plugin, name: "same", overall: :fail}),
          status(%{
            plugin: :erlang_plugin,
            name: "aaa",
            source: :unknown,
            overall: :unverifiable
          }),
          status(%{
            plugin: KilnCMS.FixturePlugin,
            name: "zzz",
            source: :overlay,
            overall: :not_applicable
          }),
          status(%{plugin: Ok.Plugin, name: "mmm", overall: :ok})
        ])
      )

    assert Enum.map(body["plugins"], &{&1["name"], &1["id"]}) == [
             {"aaa", "erlang_plugin"},
             {"mmm", "Ok.Plugin"},
             {"same", "Alpha.Plugin"},
             {"same", "Zeta.Plugin"},
             {"zzz", "KilnCMS.FixturePlugin"}
           ]

    assert body["counts"] == %{
             "fail" => 1,
             "warn" => 1,
             "unknown" => 0,
             "unverifiable" => 1,
             "not_applicable" => 1,
             "ok" => 1
           }

    assert body["counts"] |> Map.values() |> Enum.sum() == length(body["plugins"])
  end
end
