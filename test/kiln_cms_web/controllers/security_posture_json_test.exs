defmodule KilnCMSWeb.SecurityPostureJSONTest do
  @moduledoc """
  `KilnCMSWeb.SecurityPostureJSON` (#2521) on a report built by hand, the way
  no runner would build it: every source, an error row with no result,
  invalid UTF-8 where the sanitizer would have caught it, and fields that
  must never be published. It still encodes, with exactly the public keys.
  """
  use ExUnit.Case, async: true

  alias Kiln.Security.Check.Result
  alias KilnCMS.Security.Posture
  alias KilnCMS.Security.Posture.Entry
  alias KilnCMS.Security.Posture.Report
  alias KilnCMSWeb.SecurityPostureJSON

  @check_keys ~w(docs_url error facts fix_path id plugin scope source status summary title)

  defp report do
    entries = [
      %Entry{
        id: "z.plugin",
        title: "Plugin " <> <<0xFF>>,
        description: "A secret description",
        scope: :site,
        source: {:plugin, "p" <> <<0xFF>>},
        status: :warn,
        duration_ms: 12,
        result: %Result{
          status: :warn,
          summary: "Two " <> <<0xFE>>,
          details: ["someone@example.com"],
          fix_path: "/editor/x",
          docs_url: "https://example.com/d",
          facts: %{
            "n" => 2,
            :atom_key => "v" <> <<0xFF>>,
            "list" => [1],
            "nil" => nil,
            {1, 2} => 1
          }
        }
      },
      %Entry{
        id: "a.core",
        title: "Core",
        scope: :deployment,
        source: :core,
        status: :pass,
        result: Result.new(:pass, "Fine.")
      },
      %Entry{
        id: "m.config",
        title: "Config",
        scope: :site,
        source: :config,
        status: :error,
        error: :timeout,
        result: nil
      }
    ]

    %Report{
      org_id: "00000000-0000-0000-0000-000000000001",
      scopes: [:site, :deployment],
      entries: entries,
      overall: Posture.overall(entries),
      counts: Posture.counts(entries),
      ran_at: ~U[2026-11-10 09:00:00.123456Z]
    }
  end

  test "encodes, with exactly the public keys, sorted by id" do
    body = SecurityPostureJSON.show(%{report: report()})
    json = Jason.encode!(body)

    assert body |> Map.keys() |> Enum.sort() ==
             ~w(checks counts generated_at org_id scopes status version)

    assert body["version"] == SecurityPostureJSON.version()
    assert body["version"] == 1
    assert body["generated_at"] == "2026-11-10T09:00:00Z"
    assert body["scopes"] == ["site", "deployment"]
    assert body["status"] == "warn"

    assert body["counts"] == %{
             "fail" => 0,
             "warn" => 1,
             "error" => 1,
             "unknown" => 0,
             "pass" => 1,
             "n_a" => 0
           }

    assert Enum.map(body["checks"], & &1["id"]) == ["a.core", "m.config", "z.plugin"]

    for check <- body["checks"], do: assert(check |> Map.keys() |> Enum.sort() == @check_keys)

    refute json =~ "someone@example.com"
    refute json =~ "A secret description"
    refute json =~ "duration"
  end

  test "flattens sources, replaces invalid UTF-8 and keeps only scalar facts" do
    [core, config, plugin] = SecurityPostureJSON.show(%{report: report()})["checks"]

    assert %{"source" => "core", "plugin" => nil, "scope" => "deployment", "status" => "pass"} =
             core

    assert %{
             "source" => "config",
             "plugin" => nil,
             "status" => "error",
             "error" => "timeout",
             "summary" => nil,
             "fix_path" => nil,
             "docs_url" => nil,
             "facts" => facts
           } = config

    assert facts == %{}

    assert %{
             "source" => "plugin",
             "plugin" => "p�",
             "title" => "Plugin �",
             "summary" => "Two �",
             "error" => nil
           } = plugin

    assert plugin["facts"] == %{"n" => 2, "atom_key" => "v�", "list" => nil, "nil" => nil}
  end
end
