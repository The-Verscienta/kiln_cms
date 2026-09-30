defmodule KilnCMSWeb.DevAssetsTest do
  # #1761: a stale or failed local asset build is reported, not silent.
  use ExUnit.Case, async: true

  alias KilnCMSWeb.DevAssets

  @moduletag :tmp_dir

  @source """
  /* --in-a-comment: 1px; is not a declaration */
  @theme {
    --color-unused-by-anything: oklch(50% 0 0);
  }
  @layer components {
    :root {
      --side-w: 16rem;
    }
    .grid-shell { grid-template-columns: var(--side-w, 16rem) 1fr; }
  }
  """

  defp build!(root, css, opts \\ []) do
    File.mkdir_p!(Path.join(root, "assets/css"))
    File.write!(Path.join(root, "assets/css/app.css"), @source)

    if css do
      File.mkdir_p!(Path.join(root, "priv/static/assets/css"))
      File.write!(Path.join(root, "priv/static/assets/css/app.css"), css)
    end

    unless opts[:no_js] do
      File.mkdir_p!(Path.join(root, "priv/static/assets/js"))
      File.write!(Path.join(root, "priv/static/assets/js/app.js"), "")
    end

    unless opts[:no_node_modules], do: File.mkdir_p!(Path.join(root, "assets/node_modules"))
    root
  end

  test "a build that carries every declared token is sound", %{tmp_dir: root} do
    build!(root, ":root{--side-w:16rem}")
    assert DevAssets.check(root) == []
    assert DevAssets.message([]) == nil
  end

  test "a build that predates a token is stale, whatever the timestamps say", %{tmp_dir: root} do
    build!(root, ":root{--something-older:1px}")
    # Newer than the source, as a touched-but-identical rebuild would leave it.
    File.touch!(Path.join(root, "priv/static/assets/css/app.css"), System.os_time(:second) + 60)

    assert [{:stale, _built, ["--side-w"]}] = DevAssets.check(root)
  end

  test "comments and @theme blocks do not count as declarations", %{tmp_dir: root} do
    build!(root, ":root { --side-w: 16rem; }")
    assert DevAssets.check(root) == []
  end

  test "missing bundles and node_modules are named, with the setup step", %{tmp_dir: root} do
    build!(root, nil, no_js: true, no_node_modules: true)

    problems = DevAssets.check(root)
    missing = for {:missing, path} <- problems, do: Path.relative_to(path, root)
    assert missing == ["priv/static/assets/css/app.css", "priv/static/assets/js/app.js"]
    assert :no_node_modules in problems

    message = DevAssets.message(problems)
    assert message =~ "mix assets.setup && mix assets.build"
    assert message =~ "assets/node_modules is missing"
  end

  test "a stale stylesheet alone points at assets.build", %{tmp_dir: root} do
    build!(root, "")
    message = root |> DevAssets.check() |> DevAssets.message()

    assert message =~ "lacks --side-w"
    assert message =~ "`mix assets.build`"
    refute message =~ "assets.setup"
  end

  test "the real stylesheet source declares the console's width token" do
    # Guards the scan itself: if it stopped finding `--side-w`, the check would
    # pass every stale build that lacks it (#1755).
    root = Path.expand("../..", __DIR__)
    source = File.read!(Path.join(root, "assets/css/app.css"))
    scratch = Path.join(System.tmp_dir!(), "dev-assets-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(scratch) end)

    File.mkdir_p!(Path.join(scratch, "assets/css"))
    File.write!(Path.join(scratch, "assets/css/app.css"), source)
    File.mkdir_p!(Path.join(scratch, "priv/static/assets/css"))
    File.write!(Path.join(scratch, "priv/static/assets/css/app.css"), "")

    assert [{:stale, _built, missing} | _rest] = DevAssets.check(scratch)
    assert "--side-w" in missing
  end

  test "outside a dev build nothing starts and nothing is reported" do
    refute DevAssets.enabled?()
    assert DevAssets.start_link([]) == :ignore
    assert DevAssets.problems() == []
  end
end
