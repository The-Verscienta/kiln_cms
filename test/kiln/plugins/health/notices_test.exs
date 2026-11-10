defmodule Kiln.Plugins.Health.NoticesTest do
  @moduledoc """
  Reading security notices for the plugin health check (#2244): the
  kilncms.dev feed's paging and origin rule, and both sources' parsing.
  """
  use ExUnit.Case, async: true

  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.Notices

  @url "https://kilncms.dev/api/json/entries/published"
  @opts [req_options: [plug: {Req.Test, __MODULE__}]]

  defp entry(id, fields) do
    %{"id" => id, "attributes" => %{"title" => "Notice #{id}", "custom_fields" => fields}}
  end

  defp stub(fun) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:request, conn.host, conn.request_path, conn.query_string})
      fun.(conn)
    end)
  end

  defp requests do
    receive do
      {:request, host, path, query} -> [{host, path, query} | requests()]
    after
      0 -> []
    end
  end

  describe "fetch/2" do
    test "asks for security notices with a fixed query and parses them" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "data" => [entry("1", %{"package" => "kiln_ratings", "severity" => "high"})]
        })
      end)

      assert {:ok, [%Notice{packages: ["kiln_ratings"], severity: :high, source: :kiln}]} =
               Notices.fetch(@url, @opts)

      assert [{"kilncms.dev", "/api/json/entries/published", query}] = requests()

      assert URI.decode_query(query) == %{
               "filter[type_name]" => "security_notice",
               "fields[entry]" => "title,custom_fields",
               "page[limit]" => "100"
             }
    end

    test "follows a same-origin next link" do
      stub(fn conn ->
        if conn.query_string =~ "page%5Bafter%5D" do
          Req.Test.json(conn, %{"data" => [entry("2", %{"package" => "b"})]})
        else
          Req.Test.json(conn, %{
            "data" => [entry("1", %{"package" => "a"})],
            "links" => %{"next" => @url <> "?page%5Bafter%5D=x"}
          })
        end
      end)

      assert {:ok, [%{packages: ["a"]}, %{packages: ["b"]}]} = Notices.fetch(@url, @opts)
      assert length(requests()) == 2
    end

    test "does not follow a next link to another origin, and calls the list incomplete" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "data" => [entry("1", %{"package" => "a"})],
          "links" => %{"next" => "https://elsewhere.example/api/json/entries/published?p=2"}
        })
      end)

      assert Notices.fetch(@url, @opts) == {:error, :truncated}
      assert [{"kilncms.dev", _, _}] = requests()
    end

    test "stops after five pages whatever next says, and calls the list incomplete" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "data" => [entry("1", %{"package" => "a"})],
          "links" => %{"next" => @url <> "?again=1"}
        })
      end)

      assert Notices.fetch(@url, @opts) == {:error, :truncated}
      assert length(requests()) == 5
    end

    test "a failure is an error, never an empty list" do
      stub(&Plug.Conn.send_resp(&1, 500, ""))
      assert Notices.fetch(@url, @opts) == {:error, {:http_status, 500}}

      stub(&Req.Test.json(&1, %{"errors" => []}))
      assert Notices.fetch(@url, @opts) == {:error, :unparseable}

      stub(&Plug.Conn.send_resp(&1, 200, "not json"))
      assert Notices.fetch(@url, @opts) == {:error, :unparseable}

      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:error, _reason} = Notices.fetch(@url, @opts)
    end

    test "a body over the cap is an error" do
      stub(&Plug.Conn.send_resp(&1, 200, String.duplicate(" ", 1_000_001)))
      assert {:error, "response exceeded 1000000 bytes"} = Notices.fetch(@url, @opts)
    end
  end

  describe "parse_entries/1" do
    test "reads the fields the publishing script writes" do
      [notice] =
        Notices.parse_entries([
          entry("e1", %{
            "package" => "kiln_cms, kiln_ratings",
            "affected_versions" => ">= 1.0.0, < 1.3.2",
            "severity" => "Medium",
            "advisory_id" => "GHSA-aaaa-bbbb-cccc",
            "cve_id" => "CVE-2026-1",
            "advisory_url" => "https://github.com/The-Verscienta/kiln_cms/security/advisories/x"
          })
        ])

      assert notice == %Notice{
               id: "GHSA-aaaa-bbbb-cccc",
               aliases: ["CVE-2026-1"],
               title: "Notice e1",
               packages: ["kiln_cms", "kiln_ratings"],
               affected: ">= 1.0.0, < 1.3.2",
               severity: :medium,
               url: "https://github.com/The-Verscienta/kiln_cms/security/advisories/x",
               source: :kiln
             }
    end

    test "keeps patched_versions as published; absent or blank is nil" do
      [patched, unknown, blank, absent] =
        Notices.parse_entries([
          entry("1", %{"package" => "kiln_cms", "patched_versions" => " 1.3.2; 1.2.4 "}),
          entry("2", %{"package" => "kiln_cms", "patched_versions" => "unknown"}),
          entry("3", %{"package" => "kiln_cms", "patched_versions" => "  "}),
          entry("4", %{"package" => "kiln_cms"})
        ])

      assert patched.patched == "1.3.2; 1.2.4"
      assert unknown.patched == "unknown"
      assert blank.patched == nil
      assert absent.patched == nil
    end

    test "skips entries without a package, and keeps only http(s) links" do
      notices =
        Notices.parse_entries([
          entry("1", %{"severity" => "high"}),
          entry("2", %{"package" => " , "}),
          entry("3", %{"package" => "a", "advisory_url" => "javascript:alert(1)"}),
          %{"id" => "4"}
        ])

      assert [%Notice{id: "3", url: nil, severity: :unknown}] = notices
    end
  end

  describe "from_hex_release/2" do
    test "maps advisories and drops withdrawn ones" do
      release = %{
        "security_advisories" => [
          %{
            "id" => "EEF-1",
            "aliases" => ["CVE-1"],
            "summary" => "bad",
            "cvss_rating" => "critical",
            "html_url" => "https://osv.dev/vulnerability/EEF-1",
            "affected" => [">= 1.0.0 and < 2.0.0"],
            "withdrawn_at" => nil
          },
          %{"id" => "EEF-2", "withdrawn_at" => "2026-01-01T00:00:00Z"}
        ]
      }

      assert [
               %Notice{
                 id: "EEF-1",
                 aliases: ["CVE-1"],
                 packages: ["jason"],
                 severity: :critical,
                 affected: ">= 1.0.0 and < 2.0.0",
                 source: :hex
               }
             ] = Notices.from_hex_release(release, "jason")
    end

    test "a release without advisories has none" do
      assert Notices.from_hex_release(%{}, "jason") == []
    end
  end
end
