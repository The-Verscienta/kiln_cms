defmodule Kiln.Plugins.Health.EvaluateTest do
  @moduledoc """
  The pure core of the plugin health check (#2244).

  The integrity case at the top is the mutation test the issue asks for: it
  feeds a real Hex release whose checksum differs from the lock by one
  character and requires a mismatch and an overall `:fail`. With the
  comparison in `Evaluate.integrity/2` replaced by a constant `:ok`, "a
  release whose checksum changed on Hex is a mismatch and fails" fails; see
  the moduledoc there.
  """
  use ExUnit.Case, async: true

  alias Kiln.Plugins.Health.Evaluate
  alias Kiln.Plugins.Health.Installed
  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.PluginStatus

  @fixtures Path.expand("../../../support/fixtures/hex", __DIR__)

  # jason 1.4.5's outer checksum, as mix.lock and hex.pm both record it.
  @locked "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"
  # The same checksum with its last character changed.
  @tampered "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30685"

  @now ~U[2026-11-09 12:00:00Z]
  @opts [now: @now, stale_after_months: 24, sdk_version: "1.5.0"]

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp release(overrides \\ %{}),
    do: Map.merge(fixture("jason_release_1.4.5.json"), overrides)

  defp package(overrides \\ %{}), do: Map.merge(fixture("jason_package.json"), overrides)

  defp hex_ok(release \\ release(), package \\ package()),
    do: {:ok, %{package: package, release: release}}

  defp installed(overrides \\ %{}) do
    struct!(
      %Installed{
        plugin: FakeHexPlugin,
        name: "Fake Hex plugin",
        app: :jason,
        source: :hex,
        package: "jason",
        version: "1.4.5",
        repo: "hexpm",
        outer_checksum: @locked,
        sdk_requirement: "~> 1.4"
      },
      overrides
    )
  end

  defp git(overrides \\ %{}) do
    struct!(
      %Installed{
        plugin: FakeGitPlugin,
        name: "Fake git plugin",
        app: :kiln_maps,
        source: :git,
        version: "0.2.0",
        git_url: "https://example.com/kiln_maps.git",
        git_ref: "0123456789abcdef0123456789abcdef01234567",
        sdk_requirement: "~> 1.4"
      },
      overrides
    )
  end

  defp evaluate_one(installed, hex, notices \\ {:ok, []}, opts \\ @opts) do
    [status] =
      Evaluate.evaluate([installed], %{hex: %{installed.package => hex}, notices: notices}, opts)

    status
  end

  defp notice(overrides) do
    struct!(
      %Notice{
        id: "KILN-2026-0001",
        source: :kiln,
        packages: ["jason"],
        affected: ">= 1.0.0, < 2.0.0",
        severity: :high
      },
      overrides
    )
  end

  describe "integrity — the mutation test" do
    test "the tampered checksum really differs from the locked one" do
      refute @tampered == @locked
      assert byte_size(@tampered) == byte_size(@locked)
    end

    test "the recorded release matches the lock" do
      assert release()["checksum"] == @locked
      assert %PluginStatus{integrity: :ok, overall: :ok} = evaluate_one(installed(), hex_ok())
    end

    test "a release whose checksum changed on Hex is a mismatch and fails" do
      status = evaluate_one(installed(), hex_ok(release(%{"checksum" => @tampered})))

      assert status.integrity == {:mismatch, %{locked: @locked, registry: @tampered}}
      assert status.overall == :fail
    end

    test "the comparison ignores case" do
      upper = String.upcase(@locked)
      assert Evaluate.integrity(installed(), hex_ok(release(%{"checksum" => upper}))) == :ok

      assert Evaluate.integrity(
               installed(outer_checksum: upper),
               hex_ok(release(%{"checksum" => @locked}))
             ) == :ok
    end

    test "a release document without a checksum is unknown, never ok" do
      assert Evaluate.integrity(installed(), hex_ok(Map.delete(release(), "checksum"))) ==
               :unknown

      assert Evaluate.integrity(installed(), hex_ok(release(%{"checksum" => 42}))) == :unknown
    end
  end

  describe "integrity — sources and failures" do
    test "a git plugin is unverifiable" do
      assert Evaluate.integrity(git(), :not_applicable) == {:unverifiable, :git}
    end

    test "a path plugin is unverifiable" do
      assert Evaluate.integrity(git(source: :path), :not_applicable) == {:unverifiable, :path}
    end

    test "a plugin in no application is unverifiable" do
      assert Evaluate.integrity(git(source: :unknown), :not_applicable) ==
               {:unverifiable, :unknown_source}
    end

    test "an overlay plugin is not applicable" do
      assert Evaluate.integrity(git(source: :overlay), :not_applicable) == :not_applicable
    end

    test "a private repository is unverifiable, whatever Hex would say" do
      assert Evaluate.integrity(installed(repo: "acme"), hex_ok()) ==
               {:unverifiable, :private_repo}
    end

    test "an old lock entry with no outer checksum is unverifiable" do
      assert Evaluate.integrity(installed(outer_checksum: nil), hex_ok()) ==
               {:unverifiable, :no_checksum}
    end

    test "404 is not_found; any other failure is unknown; off is disabled" do
      assert Evaluate.integrity(installed(), {:error, :not_found}) == :not_found
      assert Evaluate.integrity(installed(), {:error, :timeout}) == :unknown
      assert Evaluate.integrity(installed(), {:error, {:http_status, 503}}) == :unknown

      assert Evaluate.integrity(installed(), {:error, "response exceeded 2000000 bytes"}) ==
               :unknown

      assert Evaluate.integrity(installed(), :disabled) == :disabled
    end

    test "not_found rolls up to warn; a failure to unknown" do
      assert evaluate_one(installed(), {:error, :not_found}).overall == :warn

      status = evaluate_one(installed(), {:error, :econnrefused})
      assert status.overall == :unknown
      refute status.overall == :ok
    end

    test "a package missing from the fetched results is unknown" do
      [status] = Evaluate.evaluate([installed()], %{hex: %{}, notices: {:ok, []}}, @opts)
      assert status.integrity == :unknown
      assert status.overall == :unknown
    end

    test "a git plugin with clean notices and SDK rolls up to unverifiable" do
      status = evaluate_one(git(), :not_applicable)
      assert status.advisories == {:ok, []}
      assert status.abandonment == []
      assert status.abandonment_known?
      assert status.overall == :unverifiable
    end

    test "an overlay plugin rolls up to not_applicable, untouched by core notices" do
      core_notice = notice(packages: ["kiln_cms"], affected: ">= 0.0.0")

      status =
        evaluate_one(git(source: :overlay, app: :kiln_cms), :not_applicable, {:ok, [core_notice]})

      assert status.advisories == {:ok, []}
      assert status.overall == :not_applicable
    end
  end

  describe "advisories — kilncms.dev notices" do
    test "a notice whose range covers the installed version is matched" do
      matched = notice(severity: :high)
      status = evaluate_one(installed(), hex_ok(), {:ok, [matched]})

      assert status.advisories == {:ok, [matched]}
      assert status.overall == :fail
    end

    test "high and critical notices fail; low and medium warn; unknown severity fails" do
      for {severity, overall} <- [
            critical: :fail,
            high: :fail,
            unknown: :fail,
            medium: :warn,
            low: :warn
          ] do
        status = evaluate_one(installed(), hex_ok(), {:ok, [notice(severity: severity)]})
        assert status.overall == overall, "severity #{severity} should roll up to #{overall}"
      end
    end

    test "a notice outside the installed version is not matched" do
      status =
        evaluate_one(installed(), hex_ok(), {:ok, [notice(affected: ">= 1.0.0, < 1.4.5")]})

      assert status.advisories == {:ok, []}
      assert status.overall == :ok
    end

    test "a notice for another package is not matched" do
      status = evaluate_one(installed(), hex_ok(), {:ok, [notice(packages: ["kiln_cms"])]})
      assert status.advisories == {:ok, []}
    end

    test "a notice names the plugin by any of its packages, case-insensitively" do
      matched = notice(packages: ["JASON"])
      assert {:ok, [^matched]} = evaluate_one(installed(), hex_ok(), {:ok, [matched]}).advisories
    end

    # The publisher joins every package's ranges into one text, so which range
    # is the plugin's own is lost: inside one is unknown, outside all is clean.
    test "a multi-package notice whose ranges cover the version is unknown, not a match" do
      # jason 1.4.5 sits in the core's range below, not in its own (< 1.1.0).
      shared = notice(packages: ["kiln_cms", "Jason"], affected: ">= 1.0.0, < 1.5.0; < 1.1.0")
      status = evaluate_one(installed(), hex_ok(), {:ok, [shared]})

      assert status.advisories == {:unknown, []}
      assert status.overall == :unknown
    end

    test "a multi-package notice outside every range is clean" do
      shared = notice(packages: ["kiln_cms", "jason"], affected: "< 1.1.0; >= 2.0.0, < 2.1.0")
      assert evaluate_one(installed(), hex_ok(), {:ok, [shared]}).advisories == {:ok, []}
    end

    test "the app name is a candidate as well as the Hex package" do
      plugin = installed(app: :kiln_ratings, package: "kiln_ratings_hex")
      matched = notice(packages: ["kiln_ratings"])
      hex = %{"kiln_ratings_hex" => hex_ok()}

      [status] = Evaluate.evaluate([plugin], %{hex: hex, notices: {:ok, [matched]}}, @opts)
      assert status.advisories == {:ok, [matched]}
    end

    test "a git plugin is matched by app name" do
      matched = notice(packages: ["kiln_maps"], affected: "< 1.0")
      assert evaluate_one(git(), :not_applicable, {:ok, [matched]}).advisories == {:ok, [matched]}
    end

    test "a notice naming the plugin with an unreadable range is unknown, not ok" do
      for affected <- ["unknown", "lol", nil, ""] do
        status = evaluate_one(installed(), hex_ok(), {:ok, [notice(affected: affected)]})
        assert {:unknown, []} = status.advisories, "affected #{inspect(affected)}"
        assert status.overall == :unknown
      end
    end

    test "an unparseable installed version with a notice naming the plugin is unknown" do
      plugin = git(version: "not-a-version")

      status =
        evaluate_one(plugin, :not_applicable, {:ok, [notice(packages: ["kiln_maps"])]})

      assert {:unknown, _} = status.advisories
    end

    test "the notices feed failing is unknown, not clean" do
      status = evaluate_one(installed(), hex_ok(), {:error, :timeout})
      assert status.advisories == {:unknown, []}
      assert status.overall == :unknown
    end

    test "a git plugin with the feed down is unknown" do
      assert evaluate_one(git(), :not_applicable, {:error, :nxdomain}).overall == :unknown
    end

    test "the feed turned off contributes nothing" do
      assert evaluate_one(installed(), hex_ok(), :disabled).overall == :ok
    end
  end

  # #2522: `affected_versions` alone decides; `patched_versions` is display
  # text. The publisher lists only lines that have a fix, so reading it as a
  # verdict would clear an unfixed newer line or a regression range.
  describe "advisories — kilncms.dev patched versions are not a verdict" do
    test "an unfixed newer line is matched although an older line lists a fix" do
      # 1.2 fixed at 1.2.4; the 1.4 line jason sits on has no fix yet.
      unfixed = notice(affected: ">= 1.2.0, < 1.2.4; >= 1.4.0", patched: "1.2.4")
      status = evaluate_one(installed(), hex_ok(), {:ok, [unfixed]})

      assert status.advisories == {:ok, [unfixed]}
      assert status.overall == :fail
    end

    test "a regression range after an older fix is matched" do
      regression = notice(affected: ">= 1.4.0", patched: "1.3.2")
      status = evaluate_one(installed(), hex_ok(), {:ok, [regression]})

      assert status.advisories == {:ok, [regression]}
      assert status.overall == :fail
    end
  end

  describe "advisories — Hex release advisories" do
    defp hex_advisory(overrides) do
      Map.merge(
        %{
          "id" => "EEF-CVE-2026-0001",
          "aliases" => ["CVE-2026-0001", "GHSA-xxxx-yyyy-zzzz"],
          "summary" => "Something bad",
          "html_url" => "https://osv.dev/vulnerability/EEF-CVE-2026-0001",
          "cvss_rating" => "high",
          "withdrawn_at" => nil,
          "affected" => [">= 1.0.0 and < 1.4.6"]
        },
        overrides
      )
    end

    test "an advisory on the installed release is matched with its severity" do
      rel = release(%{"security_advisories" => [hex_advisory(%{})]})
      status = evaluate_one(installed(), hex_ok(rel))

      assert {:ok, [%Notice{source: :hex, id: "EEF-CVE-2026-0001", severity: :high}]} =
               status.advisories

      assert status.overall == :fail
    end

    test "cvss ratings map to severities" do
      for {rating, severity} <- [
            {"critical", :critical},
            {"high", :high},
            {"medium", :medium},
            {"low", :low},
            {"none", :low},
            {nil, :unknown}
          ] do
        rel = release(%{"security_advisories" => [hex_advisory(%{"cvss_rating" => rating})]})

        assert {:ok, [%Notice{severity: ^severity}]} =
                 evaluate_one(installed(), hex_ok(rel)).advisories
      end
    end

    test "withdrawn advisories are ignored" do
      rel =
        release(%{
          "security_advisories" => [hex_advisory(%{"withdrawn_at" => "2026-10-01T00:00:00Z"})]
        })

      assert evaluate_one(installed(), hex_ok(rel)).advisories == {:ok, []}
    end

    test "the same advisory from both sources is listed once, as Hex's" do
      rel = release(%{"security_advisories" => [hex_advisory(%{})]})
      kiln = notice(id: "KILN-1", aliases: ["CVE-2026-0001"])

      assert {:ok, [%Notice{source: :hex}]} =
               evaluate_one(installed(), hex_ok(rel), {:ok, [kiln]}).advisories
    end

    test "Hex unavailable leaves advisories unknown for a hex plugin" do
      assert {:unknown, []} = evaluate_one(installed(), {:error, :timeout}).advisories
    end
  end

  describe "parse_affected/1 and affected?/2" do
    defp affected?(range, version) do
      {:ok, requirements} = Evaluate.parse_affected(range)
      Evaluate.affected?(version, requirements)
    end

    test "comma and ' and ' both join bounds" do
      assert affected?(">= 1.0.0, < 1.3.2", "1.3.1")
      refute affected?(">= 1.0.0, < 1.3.2", "1.3.2")
      assert affected?(">= 1.0.0 and < 1.3.2", "1.0.0")
      refute affected?(">= 1.0.0 and < 1.3.2", "0.9.9")
    end

    test "short versions are padded" do
      assert affected?("< 2.0", "1.9.9")
      refute affected?("< 2.0", "2.0.0")
      assert affected?(">= 1", "1.0.0")
    end

    test "= and a bare version mean exactly that version" do
      assert affected?("= 1.2.0", "1.2.0")
      refute affected?("= 1.2.0", "1.2.1")
      assert affected?("1.2.0", "1.2.0")
      refute affected?("1.2", "1.2.1")
    end

    test "; separates alternatives, any of which is enough" do
      range = ">= 1.0.0, < 1.3.2; >= 2.0.0 and < 2.1.1"
      assert affected?(range, "1.3.0")
      assert affected?(range, "2.1.0")
      refute affected?(range, "1.5.0")
      refute affected?(range, "2.1.1")
    end

    test "pre-releases match" do
      assert affected?(">= 1.4.1 and <= 1.5.0-pre1", "1.5.0-pre1")
      assert affected?(">= 1.4.1 and <= 1.5.0-pre1", "1.5.0-pre0")
      assert affected?("< 2.0.0", "2.0.0-rc.1")
    end

    test "~> keeps its own meaning" do
      assert affected?("~> 1.2", "1.9.0")
      refute affected?("~> 1.2.0", "1.3.0")
    end

    test "anything else is :error" do
      for text <- ["unknown", "lol", "", " ; ", ">= ", "< 1.0.0, banana", nil, 42] do
        assert Evaluate.parse_affected(text) == :error, "#{inspect(text)} should not parse"
      end
    end
  end

  describe "abandonment" do
    test "a release retired as deprecated warns" do
      rel = release(%{"retirement" => %{"reason" => "deprecated", "message" => "use x"}})
      status = evaluate_one(installed(), hex_ok(rel))

      assert status.abandonment == [{:retired, :deprecated, "use x"}]
      assert status.overall == :warn
    end

    test "a release retired for security fails" do
      rel = release(%{"retirement" => %{"reason" => "security", "message" => "CVE-1"}})
      status = evaluate_one(installed(), hex_ok(rel))

      assert status.abandonment == [{:retired, :security, "CVE-1"}]
      assert status.overall == :fail
    end

    test "an unrecognised retirement reason reads as :other" do
      rel = release(%{"retirement" => %{"reason" => "whatever"}})
      assert [{:retired, :other, nil}] = evaluate_one(installed(), hex_ok(rel)).abandonment
    end

    defp releases_at(at), do: package(%{"releases" => [%{"inserted_at" => at}]})

    test "no release in 25 months is stale; 23 is not" do
      old = DateTime.shift(@now, month: -25) |> DateTime.to_iso8601()
      recent = DateTime.shift(@now, month: -23) |> DateTime.to_iso8601()

      assert [{:stale, %DateTime{}}] =
               evaluate_one(installed(), hex_ok(release(), releases_at(old))).abandonment

      assert evaluate_one(installed(), hex_ok(release(), releases_at(old))).overall == :warn
      assert evaluate_one(installed(), hex_ok(release(), releases_at(recent))).abandonment == []
    end

    test "the threshold comes from the options" do
      old = DateTime.shift(@now, month: -13) |> DateTime.to_iso8601()
      opts = Keyword.put(@opts, :stale_after_months, 12)

      assert [{:stale, _}] =
               evaluate_one(installed(), hex_ok(release(), releases_at(old)), {:ok, []}, opts).abandonment
    end

    test "a package with no readable release dates is not known" do
      status = evaluate_one(installed(), hex_ok(release(), package(%{"releases" => []})))
      refute status.abandonment_known?
      assert status.overall == :unknown
    end

    test "an unsatisfied SDK requirement warns" do
      status = evaluate_one(installed(sdk_requirement: "~> 2.0"), hex_ok())
      assert status.abandonment == [{:sdk_unsupported, "~> 2.0", "1.5.0"}]
      assert status.overall == :warn
    end

    test "an invalid SDK requirement warns" do
      status = evaluate_one(installed(sdk_requirement: "banana"), hex_ok())
      assert status.abandonment == [{:sdk_requirement_invalid, "banana"}]
      assert status.overall == :warn
    end

    test "a hex plugin with no lock requirement falls back to the release's" do
      rel =
        release(%{
          "requirements" => %{
            "kiln_plugin" => %{"app" => "kiln_plugin", "requirement" => "~> 3.0"}
          }
        })

      status = evaluate_one(installed(sdk_requirement: nil), hex_ok(rel))
      assert status.abandonment == [{:sdk_unsupported, "~> 3.0", "1.5.0"}]
    end

    test "a hex plugin with no requirement anywhere has none to fail" do
      status = evaluate_one(installed(sdk_requirement: nil), hex_ok())
      assert status.abandonment == []
      assert status.abandonment_known?
    end

    test "an unknown SDK requirement (Mix's graph unreadable) is not known" do
      status = evaluate_one(git(sdk_requirement: :unknown), :not_applicable)
      refute status.abandonment_known?
      assert status.overall == :unknown
    end

    test "an unknown bundled SDK version is not known" do
      opts = Keyword.put(@opts, :sdk_version, nil)
      refute evaluate_one(git(), :not_applicable, {:ok, []}, opts).abandonment_known?
    end

    test "the SDK is still checked when the remote checks are disabled" do
      [status] =
        Evaluate.evaluate(
          [git(sdk_requirement: "~> 2.0")],
          %{hex: :disabled, notices: :disabled},
          @opts
        )

      assert status.abandonment == [{:sdk_unsupported, "~> 2.0", "1.5.0"}]
      assert status.overall == :warn
    end

    test "staleness is not checked for a git plugin and does not lower it" do
      status = evaluate_one(git(), :not_applicable)
      assert status.abandonment_known?
    end

    test "Hex unavailable leaves a hex plugin's abandonment unknown" do
      refute evaluate_one(installed(), {:error, :timeout}).abandonment_known?
    end
  end

  describe "sdk/2" do
    test "answers" do
      assert Evaluate.sdk("~> 1.4", "1.5.0") == :ok
      assert Evaluate.sdk(nil, "1.5.0") == :ok
      assert Evaluate.sdk("~> 2.0", "1.5.0") == {:unsatisfied, "~> 2.0", "1.5.0"}
      assert Evaluate.sdk("nope", "1.5.0") == {:invalid, "nope"}
      assert Evaluate.sdk(:unknown, "1.5.0") == :unknown
      assert Evaluate.sdk("~> 1.4", nil) == :unknown
      assert Evaluate.sdk("~> 1.4", "garbage") == :unknown
    end
  end

  describe "latest_version" do
    test "comes from the package's latest stable version" do
      assert evaluate_one(installed(), hex_ok()).latest_version ==
               package()["latest_stable_version"]
    end
  end

  describe "rollup/1 exhaustiveness" do
    @clean %PluginStatus{
      plugin: FakeHexPlugin,
      name: "x",
      source: :hex,
      integrity: :ok,
      advisories: {:ok, []},
      abandonment: [],
      abandonment_known?: true
    }

    test "only a fully clean status is ok" do
      assert Evaluate.rollup(@clean) == :ok
    end

    test "every non-ok input, with everything else clean, is never ok" do
      some_notice = notice(severity: :low)

      variations =
        [
          integrity: {:mismatch, %{locked: @locked, registry: @tampered}},
          integrity: :not_found,
          integrity: {:unverifiable, :git},
          integrity: {:unverifiable, :path},
          integrity: {:unverifiable, :private_repo},
          integrity: {:unverifiable, :no_checksum},
          integrity: {:unverifiable, :unknown_source},
          integrity: :not_applicable,
          integrity: :unknown,
          integrity: :disabled,
          advisories: {:unknown, []},
          advisories: {:unknown, [some_notice]},
          abandonment_known?: false,
          abandonment: [{:retired, :security, nil}],
          abandonment: [{:retired, :deprecated, nil}],
          abandonment: [{:stale, @now}],
          abandonment: [{:sdk_unsupported, "~> 2.0", "1.5.0"}],
          abandonment: [{:sdk_requirement_invalid, "x"}]
        ] ++
          for(
            severity <- [:low, :medium, :high, :critical, :unknown],
            do: {:advisories, {:ok, [notice(severity: severity)]}}
          )

      for {field, value} <- variations do
        status = Map.put(@clean, field, value)

        refute Evaluate.rollup(status) == :ok,
               "#{field}: #{inspect(value)} rolled up to :ok"
      end
    end

    test "the order is fail, warn, unknown, unverifiable, not_applicable" do
      mismatch = {:mismatch, %{locked: @locked, registry: @tampered}}

      assert Evaluate.rollup(%{@clean | integrity: mismatch, advisories: {:unknown, []}}) ==
               :fail

      assert Evaluate.rollup(%{@clean | integrity: :not_found, advisories: {:unknown, []}}) ==
               :warn

      assert Evaluate.rollup(%{
               @clean
               | integrity: {:unverifiable, :git},
                 advisories: {:unknown, []}
             }) ==
               :unknown

      assert Evaluate.rollup(%{@clean | integrity: {:unverifiable, :git}}) == :unverifiable
      assert Evaluate.rollup(%{@clean | integrity: :not_applicable}) == :not_applicable
    end
  end
end
