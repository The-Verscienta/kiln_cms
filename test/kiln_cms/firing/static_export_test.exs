defmodule KilnCMS.Firing.StaticExportTest do
  @moduledoc "First-class static / edge export of fired artifacts (#353)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.StaticExport
  alias KilnCMS.Firing.StaticExportWorker

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "exp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Create + publish + fire a page, returning its slug.
  defp fired_page(attrs \\ %{}) do
    actor = admin()
    slug = "exp-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        Map.merge(
          %{
            title: "Exported",
            slug: slug,
            blocks: [%{type: :heading, content: "Edge", data: %{"level" => 1}, order: 0}]
          },
          attrs
        ),
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    drain_oban()
    slug
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kiln-export-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "exports each fired surface to the static tree" do
    slug = fired_page()
    out = tmp_dir()

    {:ok, result} = StaticExport.export(out)

    base = Path.join([out, "content", "page", "en", slug])
    assert File.exists?(Path.join(base, "web.html"))
    assert File.exists?(Path.join(base, "json.json"))
    assert File.exists?(Path.join(base, "json_ld.json"))

    # The exported bodies are the fired artifacts, unmodified (no re-render).
    assert File.read!(Path.join(base, "web.html")) =~ "Edge"
    json = Path.join(base, "json.json") |> File.read!() |> Jason.decode!()
    assert json["type"] == "page"
    assert json["slug"] == slug

    json_ld = Path.join(base, "json_ld.json") |> File.read!() |> Jason.decode!()
    assert json_ld["@context"] == "https://schema.org"

    assert result.count >= 1
  end

  test "writes an index.json manifest listing exported documents" do
    slug = fired_page()
    out = tmp_dir()

    {:ok, _} = StaticExport.export(out, base_url: "https://cdn.example.test")

    manifest = Path.join(out, "index.json") |> File.read!() |> Jason.decode!()
    assert manifest["generator"] == "kiln-static-export"
    assert manifest["base_url"] == "https://cdn.example.test"
    assert manifest["surfaces"] == ["web", "json", "json_ld"]

    entry = Enum.find(manifest["entries"], &(&1["slug"] == slug))
    assert entry["type"] == "page"
    assert entry["locale"] == "en"
    assert entry["path"] == "content/page/en/#{slug}"
    assert Enum.sort(entry["surfaces"]) == ["json", "json_ld", "web"]
  end

  test "namespaces non-default locales" do
    actor = admin()
    slug = "exp-fr-#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "Bonjour", slug: slug, locale: "fr"}, actor: actor)
    CMS.publish_page!(page, actor: actor)
    drain_oban()

    out = tmp_dir()
    {:ok, _} = StaticExport.export(out)

    assert File.exists?(Path.join([out, "content", "page", "fr", slug, "json.json"]))
  end

  test "the :surfaces option restricts what is written" do
    slug = fired_page()
    out = tmp_dir()

    {:ok, result} = StaticExport.export(out, surfaces: [:json])

    base = Path.join([out, "content", "page", "en", slug])
    assert File.exists?(Path.join(base, "json.json"))
    refute File.exists?(Path.join(base, "web.html"))
    refute File.exists?(Path.join(base, "json_ld.json"))
    assert result.surfaces == [:json]
  end

  test "skips (and counts) a published document that has never been fired" do
    actor = admin()
    slug = "exp-nofire-#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "Pending", slug: slug, blocks: []}, actor: actor)
    # Publish but DON'T drain — no artifact is fired yet.
    CMS.publish_page!(page, actor: actor)

    out = tmp_dir()
    {:ok, result} = StaticExport.export(out)

    refute File.exists?(Path.join([out, "content", "page", "en", slug]))
    assert result.skipped >= 1
  end

  test "skips a document whose locale would escape the output directory (no traversal)" do
    actor = admin()
    slug = "exp-trav-#{System.unique_integer([:positive])}"
    marker = "kiln-evil-#{System.unique_integer([:positive])}"
    evil_dir = Path.join(System.tmp_dir!(), marker)
    on_exit(fn -> File.rm_rf!(evil_dir) end)

    # locale is an unconstrained attribute; a crafted one must not redirect writes.
    # Enough `../` to climb to the filesystem root from any out_dir, then into /tmp.
    out = tmp_dir()
    evil_locale = String.duplicate("../", 20) <> "tmp/#{marker}"

    page =
      CMS.create_page!(
        %{
          title: "Evil",
          slug: slug,
          locale: evil_locale,
          blocks: [%{type: :heading, content: "x", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    drain_oban()

    {:ok, result} = StaticExport.export(out)

    # The entry was skipped and nothing was written to the traversal target.
    refute Enum.any?(result.entries, &(&1["slug"] == slug))
    refute File.exists?(evil_dir)
  end

  describe "StaticExportWorker" do
    test "no-ops when no output directory is configured" do
      assert :ok = StaticExportWorker.perform(%Oban.Job{args: %{}})
    end

    test "exports to the out_dir given in the job args" do
      slug = fired_page()
      out = tmp_dir()

      assert :ok = StaticExportWorker.perform(%Oban.Job{args: %{"out_dir" => out}})
      assert File.exists?(Path.join([out, "content", "page", "en", slug, "json.json"]))
    end

    test "ignores an unknown surface string instead of crashing" do
      slug = fired_page()
      out = tmp_dir()

      # A typo'd surface in the job args must not raise a FunctionClauseError.
      assert :ok =
               StaticExportWorker.perform(%Oban.Job{
                 args: %{"out_dir" => out, "surfaces" => ["json", "bogus"]}
               })

      base = Path.join([out, "content", "page", "en", slug])
      assert File.exists?(Path.join(base, "json.json"))
      refute File.exists?(Path.join(base, "web.html"))
    end
  end
end
