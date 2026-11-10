Code.require_file("../../../scripts/publish/security.exs", __DIR__)

defmodule Kiln.SecurityNotices.CoreTest do
  @moduledoc """
  Whether a published security notice covers the running core (#2522):
  affected, outside, malformed, and `patched_versions` never clearing an
  affected version. Pure; literal data only.

  The contract cases at the bottom build the notice the way it reaches an
  instance: a GitHub advisory through `scripts/publish/security.exs` (what
  kilncms.dev stores), then `Kiln.Plugins.Health.Notices.parse_entries/1`
  (what the feed answers is read with), so a change on either side that stops
  the core recognizing its own notices fails here.
  """
  use ExUnit.Case, async: true

  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.Notices
  alias Kiln.SecurityNotices.Core

  defp notice(overrides \\ []) do
    struct!(
      %Notice{
        id: "GHSA-6983-jfq8-485w",
        source: :kiln,
        packages: ["kiln_cms"],
        affected: ">= 1.3.0, < 1.3.2; >= 1.2.0, < 1.2.4",
        patched: "1.3.2; 1.2.4",
        severity: :high
      },
      overrides
    )
  end

  defp classify(notice, version), do: Core.classify(notice, Version.parse!(version))

  defp affected_ids(notices, version) do
    {:ok, status} = Core.status(notices, version)
    Enum.map(status.affected, & &1.id)
  end

  describe "the published example" do
    test "versions inside a range are affected" do
      assert classify(notice(), "1.3.1") == :affected
      assert classify(notice(), "1.2.3") == :affected
      assert classify(notice(), "1.3.0") == :affected
    end

    test "fixed and unaffected versions are not" do
      assert classify(notice(), "1.3.2") == :outside
      assert classify(notice(), "1.2.4") == :outside
      assert classify(notice(), "1.4.0") == :outside
      assert classify(notice(), "0.9.0") == :outside
    end

    test "status lists the affected notices, with the version they were placed against" do
      assert {:ok, %{version: "1.3.1", affected: [%Notice{}], unplaceable: []}} =
               Core.status([notice()], "1.3.1")

      assert affected_ids([notice()], "1.3.2") == []
    end
  end

  describe "malformed and multi-package notices" do
    test "an unreadable affected range is unplaceable" do
      for affected <- [nil, "", "unknown", "lol", ">= 1.0.0, <"] do
        assert classify(notice(affected: affected), "1.3.1") == :unplaceable,
               "affected #{inspect(affected)}"
      end

      assert {:ok, %{affected: [], unplaceable: [_]}} =
               Core.status([notice(affected: "unknown")], "1.3.1")
    end

    test "a notice naming several packages is unplaceable inside a range, outside when outside" do
      shared = notice(packages: ["kiln_cms", "kiln_seo"])

      assert classify(shared, "1.3.1") == :unplaceable
      assert classify(shared, "1.4.0") == :outside
    end

    test "a notice for a plugin only is ignored" do
      plugin = notice(packages: ["kiln_seo"])

      assert {:ok, %{affected: [], unplaceable: [], considered: []}} =
               Core.status([plugin], "1.3.1")
    end

    test "the core package is matched case- and space-insensitively" do
      assert affected_ids([notice(packages: [" Kiln_CMS "])], "1.3.1") == ["GHSA-6983-jfq8-485w"]
    end
  end

  # `affected_versions` alone decides; `patched_versions` is display text.
  # The publisher lists only lines that have a fix, so reading it as a verdict
  # would clear exactly the versions still exposed.
  describe "patched versions are not a verdict" do
    test "an unfixed newer line is affected although an older line lists a fix" do
      unfixed = notice(affected: ">= 1.2.0, < 1.2.4; >= 1.3.0", patched: "1.2.4")

      assert classify(unfixed, "1.3.1") == :affected
      assert classify(unfixed, "1.2.4") == :outside
      assert affected_ids([unfixed], "1.3.1") == ["GHSA-6983-jfq8-485w"]
    end

    test "a regression range after an older fix is affected" do
      regression = notice(affected: ">= 1.5.0", patched: "1.3.2")
      assert classify(regression, "1.5.2") == :affected
      assert classify(regression, "1.4.0") == :outside
    end

    test "a version listed as patched but inside a loose range is still affected" do
      # Strict on purpose: the range was never tightened, so it is believed.
      loose = notice(affected: ">= 1.0.0, < 2.0.0", patched: "1.3.2")
      assert classify(loose, "1.3.2") == :affected
    end

    test "absent, unknown or unreadable patched text changes nothing" do
      for patched <- [nil, "", "unknown", "lol"] do
        assert classify(notice(patched: patched), "1.3.1") == :affected,
               "patched #{inspect(patched)}"
      end
    end
  end

  describe "the running version" do
    test "release candidates are matched" do
      assert classify(notice(affected: ">= 1.0.0, < 1.9.0", patched: nil), "1.9.0-rc.1") ==
               :affected

      assert affected_ids([notice(affected: "< 2.0.0", patched: nil)], "v1.9.0-rc.1") != []
    end

    test "an unreadable version, or 0.0.0, is unknown when a notice names the core" do
      for version <- ["0.0.0", "garbage", "", nil] do
        assert Core.status([notice()], version) == {:error, :unknown_version},
               "version #{inspect(version)}"
      end
    end

    test "with no notice naming the core, an unknown version still passes" do
      assert {:ok, %{affected: [], unplaceable: []}} = Core.status([], "0.0.0")

      assert {:ok, %{affected: [], unplaceable: []}} =
               Core.status([notice(packages: ["kiln_seo"])], "garbage")
    end
  end

  describe "the publisher's contract" do
    @advisory %{
      "ghsa_id" => "GHSA-6983-jfq8-485w",
      "html_url" =>
        "https://github.com/The-Verscienta/kiln_cms/security/advisories/GHSA-6983-jfq8-485w",
      "summary" => "Preview tokens leak across tenants",
      "description" => "### Impact\n\nA leak.\n",
      "severity" => "high",
      "published_at" => "2026-10-20T13:03:19Z",
      "withdrawn_at" => nil,
      "vulnerabilities" => [
        %{
          "package" => %{"ecosystem" => "erlang", "name" => "kiln_cms"},
          "vulnerable_version_range" => ">= 1.3.0, < 1.3.2",
          "patched_versions" => "1.3.2"
        },
        %{
          "package" => %{"ecosystem" => "erlang", "name" => "kiln_cms"},
          "vulnerable_version_range" => ">= 1.2.0, < 1.2.4",
          "patched_versions" => "1.2.4"
        }
      ]
    }

    # What an instance reads back for an advisory the script published.
    defp published(advisory) do
      {:ok, notice} = PublishSecurity.notice(advisory)
      [parsed] = Notices.parse_entries([%{"attributes" => PublishSecurity.entry_attrs(notice)}])
      parsed
    end

    test "the core's published notice places against the core" do
      notice = published(@advisory)

      assert notice.patched == "1.3.2; 1.2.4"

      for {version, expected} <- [
            {"1.3.1", :affected},
            {"1.2.3", :affected},
            {"1.3.2", :outside},
            {"1.2.4", :outside},
            {"1.4.0", :outside},
            {"0.9.0", :outside}
          ] do
        assert classify(notice, version) == expected, "version #{version}"
      end
    end

    test "a line with no fix yet stays affected although the notice lists another line's fix" do
      [_newer, older] = @advisory["vulnerabilities"]

      # GitHub's `patched_versions` is null for a line with no fix; the
      # script leaves that line out of the published patched text.
      unfixed = %{
        "package" => %{"ecosystem" => "erlang", "name" => "kiln_cms"},
        "vulnerable_version_range" => ">= 1.3.0",
        "patched_versions" => nil
      }

      notice = published(%{@advisory | "vulnerabilities" => [older, unfixed]})

      assert notice.patched == "1.2.4"
      assert classify(notice, "1.3.1") == :affected
      assert classify(notice, "1.2.4") == :outside
    end

    test "an advisory naming no package is the core's, by the name Core matches" do
      unnamed = Enum.map(@advisory["vulnerabilities"], &Map.delete(&1, "package"))
      notice = published(%{@advisory | "vulnerabilities" => unnamed})

      # The script's `@core_package` is the one name Core treats as the core.
      assert notice.packages == Core.core_packages()
      assert classify(notice, "1.3.1") == :affected
    end

    test "an advisory for the core and a plugin is the core's, and unplaceable in range" do
      [core, plugin] = @advisory["vulnerabilities"]
      plugin = put_in(plugin, ["package", "name"], "kiln_seo")

      notice =
        published(%{@advisory | "vulnerabilities" => [Map.delete(core, "package"), plugin]})

      assert Core.core?(notice)
      assert classify(notice, "1.3.1") == :unplaceable
    end
  end
end
