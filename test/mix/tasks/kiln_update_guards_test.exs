defmodule Mix.Tasks.Kiln.UpdateGuardsTest do
  @moduledoc """
  What `mix kiln.update` refuses to do, and what `--check` promises not to
  refuse — against a real git repo rather than a fixture directory.

  `kiln_update_test.exs` covers the pure halves: the upgrade-note extraction,
  the Kiln-checkout predicate and the printed next steps. Everything between
  them — resolving a target, the three guards, and the exit codes — had never
  run, and those are the parts that decide whether a production pin moves.

  Two contracts are worth the fixture. **`--check` changes nothing and refuses
  nothing**: a dirty tree and a major jump are exactly what an operator runs it
  to find out about, so failing there would send them to fix the tree before
  they had read the reason. And **`--exit-code` exits 1 when an update is
  available**, which is what a CI "you are behind upstream" job reads.

  The repo is built here rather than mocked: every guard is a `git` invocation,
  so a fake would be testing the fake.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Update

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    origin = Path.join(tmp_dir, "origin")
    clone = Path.join(tmp_dir, "kiln")

    init_origin!(origin)
    git!(tmp_dir, ["clone", "--quiet", origin, clone])
    git!(clone, ["config", "user.email", "kiln@example.com"])
    git!(clone, ["config", "user.name", "Kiln"])

    %{origin: origin, clone: clone}
  end

  # A repo that looks like the Kiln core to `kiln_checkout?/1`: the marker file
  # and a mix.exs declaring `app: :kiln_cms`. Two releases, so there is
  # something to update to.
  defp init_origin!(dir) do
    File.mkdir_p!(Path.join(dir, "lib/kiln_cms"))
    git!(dir, ["init", "--quiet", "--initial-branch", "main"])
    git!(dir, ["config", "user.email", "kiln@example.com"])
    git!(dir, ["config", "user.name", "Kiln"])

    File.write!(Path.join(dir, "lib/kiln_cms/application.ex"), "defmodule X do\nend\n")
    File.write!(Path.join(dir, "mix.exs"), "def project, do: [app: :kiln_cms]\n")
    File.write!(Path.join(dir, "CHANGELOG.md"), changelog())
    commit!(dir, "first")
    git!(dir, ["tag", "v0.1.0"])

    File.write!(Path.join(dir, "README.md"), "second\n")
    commit!(dir, "second")
    git!(dir, ["tag", "v0.2.0"])

    File.write!(Path.join(dir, "README.md"), "third\n")
    commit!(dir, "third")
    git!(dir, ["tag", "v1.0.0"])
  end

  defp changelog do
    """
    # Changelog

    ## [1.0.0]

    ### Upgrade notes

    1. The overlay contract changed; recompile your subproject.

    ## [0.2.0]

    ### Breaking

    - `POST /api/thing` answers 200 where it answered 201.
    """
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", message])
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp checkout!(dir, ref), do: git!(dir, ["checkout", "--quiet", "--detach", ref])

  defp run(clone, args), do: File.cd!(clone, fn -> Update.run(args) end)

  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([IO.iodata_to_binary(line) | acc])
      {:mix_shell, :error, [line]} -> collect([IO.iodata_to_binary(line) | acc])
    after
      0 -> acc
    end
  end

  defp head(clone), do: git!(clone, ["rev-parse", "HEAD"])

  describe "--check" do
    test "reports the update without moving the pin", %{clone: clone} do
      checkout!(clone, "v0.1.0")
      before = head(clone)

      run(clone, ["--check", "--to", "v0.2.0"])

      assert output() =~ "Run without --check to move the pin."
      assert head(clone) == before
    end

    test "refuses nothing: a dirty tree and a major jump still report", %{clone: clone} do
      checkout!(clone, "v0.1.0")
      File.write!(Path.join(clone, "README.md"), "uncommitted\n")
      before = head(clone)

      # v0.1.0 -> v1.0.0 is a major jump, and the tree is dirty. Both are
      # refusals for a real update, and both are what someone runs --check to
      # find out about — so neither may stop the report.
      run(clone, ["--check"])

      assert output() =~ "Run without --check to move the pin."
      assert head(clone) == before
    end

    test "--exit-code exits 1 when an update is available", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      assert {:shutdown, 1} = catch_exit(run(clone, ["--check", "--exit-code"]))
    end

    test "--exit-code exits 0 when the pin is already the latest", %{clone: clone} do
      checkout!(clone, "v1.0.0")

      run(clone, ["--check", "--exit-code"])

      # No exit: being up to date is not a CI failure.
      assert output() =~ "Already up to date"
    end
  end

  describe "choosing a target" do
    test "the default target is the highest VERSION, not the last tag listed",
         %{clone: clone, origin: origin} do
      # `git tag --list` sorts lexically, where "v1.0.0-rc1" comes after
      # "v1.0.0" — and a prerelease is *lower* than the release. Taking the
      # last tag listed would offer an operator a release candidate as the
      # newest stable release.
      git!(origin, ["tag", "v1.0.0-rc1", "v0.2.0"])
      checkout!(clone, "v0.1.0")

      run(clone, ["--check"])
      out = output()

      assert out =~ "v1.0.0 "
      refute out =~ "rc1"
    end

    test "--to targets that release", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      run(clone, ["--check", "--to", "0.2.0"])
      out = output()

      # Normalised: `0.2.0` and `v0.2.0` name the same release.
      assert out =~ "v0.2.0"
      refute out =~ "v1.0.0"
    end

    test "--to a release that does not exist is refused by name", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      assert_raise Mix.Error, ~r/no such release: v9.9.9/, fn ->
        run(clone, ["--check", "--to", "v9.9.9"])
      end
    end

    test "--to something that is not a version says what it expected", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      assert_raise Mix.Error, ~r/--to expects a release like v0.3.0/, fn ->
        run(clone, ["--check", "--to", "latest"])
      end
    end

    test "--ref takes any commit, and skips the version comparison", %{clone: clone} do
      checkout!(clone, "v0.1.0")
      target = git!(clone, ["rev-parse", "v0.2.0"])

      run(clone, ["--ref", target, "--no-fetch"])

      assert head(clone) == target
      # A ref has no version, so the major guard cannot fire — which is the
      # documented way to track a branch deliberately.
      assert output() =~ "Pin moved."
    end

    test "--ref that resolves to nothing is refused", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      assert_raise Mix.Error, ~r/unknown ref: no-such-branch/, fn ->
        run(clone, ["--check", "--ref", "no-such-branch"])
      end
    end
  end

  # #1541: `Version` orders `1.1.0-rc.1` above `1.0.0`, so a task that takes
  # the highest tag would move every downstream pin onto the first release
  # candidate pushed. Tags are made in the clone and read with --no-fetch, so
  # each test controls exactly which releases exist.
  describe "pre-releases" do
    test "a plain update ignores a candidate newer than the latest release",
         %{clone: clone} do
      tag_candidate!(clone, "v1.1.0-rc.1")
      checkout!(clone, "v0.2.0")

      run(clone, ["--check", "--no-fetch"])
      out = output()

      assert out =~ "v0.2.0 (" and out =~ "-> v1.0.0 ("
      refute out =~ "rc.1"
    end

    test "--pre takes the newest candidate", %{clone: clone} do
      tag_candidate!(clone, "v1.1.0-rc.1")
      checkout!(clone, "v1.0.0")

      run(clone, ["--check", "--no-fetch", "--pre"])
      out = output()

      assert out =~ "-> v1.1.0-rc.1 ("
      assert out =~ "Run without --check to move the pin."
    end

    test "--pre still prefers a final release over its own candidate", %{clone: clone} do
      # 1.0.0-rc.1 < 1.0.0: the candidate is older than the release it led to.
      git!(clone, ["tag", "v1.0.0-rc.1", "v0.2.0"])
      checkout!(clone, "v0.1.0")

      run(clone, ["--check", "--no-fetch", "--pre"])
      out = output()

      assert out =~ "-> v1.0.0 ("
      refute out =~ "-> v1.0.0-rc.1"
    end

    test "--to names a candidate without --pre", %{clone: clone} do
      tag_candidate!(clone, "v1.1.0-rc.1")
      checkout!(clone, "v1.0.0")
      target = git!(clone, ["rev-parse", "v1.1.0-rc.1"])

      run(clone, ["--no-fetch", "--to", "1.1.0-rc.1"])

      assert head(clone) == target
      assert output() =~ "Pin moved."
    end

    test "--check --exit-code does not report a candidate as an update", %{clone: clone} do
      tag_candidate!(clone, "v1.1.0-rc.1")
      checkout!(clone, "v1.0.0")

      # No exit: a CI "behind upstream" job must not go red because an RC
      # exists.
      run(clone, ["--check", "--exit-code", "--no-fetch"])

      assert output() =~ "Already up to date"
    end

    test "only candidates upstream is refused, naming --pre", %{clone: clone} do
      for tag <- ["v0.1.0", "v0.2.0", "v1.0.0"], do: git!(clone, ["tag", "-d", tag])
      git!(clone, ["tag", "v1.0.0-rc.1", "HEAD"])

      assert_raise Mix.Error, ~r/only pre-releases:\nv1.0.0-rc.1.*Pass --pre/s, fn ->
        run(clone, ["--check", "--no-fetch"])
      end
    end

    test "0.x -> 1.0.0-rc.1 is a major jump: --pre alone is refused, --allow-major proceeds",
         %{clone: clone} do
      # Upstream as it will look when the first 1.0 candidate is pushed: 0.x
      # finals and one candidate. The candidate carries its notes under
      # [Unreleased], as docs/releasing.md cuts it.
      git!(clone, ["tag", "-d", "v1.0.0"])
      checkout!(clone, "v0.2.0")
      rc = tag_candidate!(clone, "v1.0.0-rc.1", unreleased_breaking: "Overlays must recompile.")
      checkout!(clone, "v0.2.0")

      # Without --pre there is nothing newer than the pin.
      run(clone, ["--no-fetch"])
      assert output() =~ "Already up to date"

      assert_raise Mix.Error, ~r/0.2.0 -> 1.0.0-rc.1 is a major-version update/, fn ->
        run(clone, ["--no-fetch", "--pre"])
      end

      assert head(clone) == git!(clone, ["rev-parse", "v0.2.0"])
      # The refusal came after the report, which printed the candidate's notes.
      assert output() =~ "Overlays must recompile."

      run(clone, ["--no-fetch", "--pre", "--allow-major"])
      assert head(clone) == rc
    end

    test "a pin on a candidate is not downgraded, and moves once the final ships",
         %{clone: clone} do
      rc = tag_candidate!(clone, "v1.1.0-rc.1")

      run(clone, ["--no-fetch"])

      assert output() =~ "Already ahead of the latest release"
      assert head(clone) == rc

      final = tag_candidate!(clone, "v1.1.0")
      checkout!(clone, rc)

      run(clone, ["--no-fetch"])

      assert head(clone) == final
    end
  end

  # A new commit on top of whatever is checked out, tagged `tag`, left
  # checked out. `unreleased_breaking:` writes an `[Unreleased]` Breaking note
  # into the changelog at that commit, the shape a candidate is tagged in.
  defp tag_candidate!(clone, tag, opts \\ []) do
    if note = opts[:unreleased_breaking] do
      File.write!(
        Path.join(clone, "CHANGELOG.md"),
        "# Changelog\n\n## [Unreleased]\n\n### Breaking\n\n- #{note}\n\n" <> changelog_body()
      )
    end

    File.write!(Path.join(clone, "README.md"), "#{tag}\n")
    commit!(clone, tag)
    git!(clone, ["tag", tag])
    head(clone)
  end

  defp changelog_body, do: String.replace_prefix(changelog(), "# Changelog\n\n", "")

  describe "the guards on a real update" do
    test "a dirty tree stops the update before anything is checked out", %{clone: clone} do
      checkout!(clone, "v0.1.0")
      File.write!(Path.join(clone, "README.md"), "mine\n")
      before = head(clone)

      assert_raise Mix.Error, ~r/uncommitted changes/, fn ->
        run(clone, ["--to", "v0.2.0", "--no-fetch"])
      end

      assert head(clone) == before
      assert File.read!(Path.join(clone, "README.md")) == "mine\n"
    end

    test "a pin carrying local commits is refused, and --force proceeds", %{clone: clone} do
      checkout!(clone, "v0.2.0")
      File.write!(Path.join(clone, "README.md"), "patched locally\n")
      commit!(clone, "local patch")
      patched = head(clone)

      assert_raise Mix.Error, ~r/has 1 commit\(s\) not in v0.2.0/, fn ->
        run(clone, ["--to", "v0.2.0", "--no-fetch"])
      end

      assert head(clone) == patched

      # --force waives the divergence check only. The pin is now a commit past
      # the tag, so it is untagged, and the major guard still fails closed —
      # one flag does not wave through the other question.
      assert_raise Mix.Error, ~r/isn't on a release tag/, fn ->
        run(clone, ["--to", "v0.2.0", "--no-fetch", "--force"])
      end

      assert head(clone) == patched

      run(clone, ["--to", "v0.2.0", "--no-fetch", "--force", "--allow-major"])
      assert head(clone) == git!(clone, ["rev-parse", "v0.2.0"])
    end

    test "a major jump is refused, and --allow-major proceeds", %{clone: clone} do
      checkout!(clone, "v0.2.0")

      assert_raise Mix.Error, ~r/0.2.0 -> 1.0.0 is a major-version update/, fn ->
        run(clone, ["--to", "v1.0.0", "--no-fetch"])
      end

      assert head(clone) == git!(clone, ["rev-parse", "v0.2.0"])

      run(clone, ["--to", "v1.0.0", "--no-fetch", "--allow-major"])
      assert head(clone) == git!(clone, ["rev-parse", "v1.0.0"])
    end

    test "an untagged pin is refused too, since the jump cannot be judged", %{clone: clone} do
      checkout!(clone, "v0.1.0")
      File.write!(Path.join(clone, "README.md"), "untagged\n")
      commit!(clone, "untagged pin")
      git!(clone, ["tag", "-d", "v0.1.0"])

      assert_raise Mix.Error, ~r/isn't on a release tag/, fn ->
        run(clone, ["--to", "v0.2.0", "--no-fetch", "--force"])
      end
    end
  end

  describe "upgrade notes in the report" do
    test "only the sections between the two pins are printed", %{clone: clone} do
      checkout!(clone, "v0.1.0")

      run(clone, ["--check", "--to", "v1.0.0"])
      out = output()

      # Both releases in the range contribute their operator sections…
      assert out =~ "The overlay contract changed"
      assert out =~ "answers 200 where it answered 201"
    end

    test "a release already installed is not repeated", %{clone: clone} do
      checkout!(clone, "v0.2.0")

      run(clone, ["--check", "--to", "v1.0.0"])
      out = output()

      assert out =~ "The overlay contract changed"
      # v0.2.0 is where the pin already is; its notes were read last time.
      refute out =~ "answers 200 where it answered 201"
    end
  end

  describe "the repo it runs in" do
    test "a repo that is not the Kiln core is refused", %{tmp_dir: tmp_dir} do
      other = Path.join(tmp_dir, "not-kiln")
      File.mkdir_p!(other)
      git!(other, ["init", "--quiet", "--initial-branch", "main"])
      git!(other, ["config", "user.email", "x@example.com"])
      git!(other, ["config", "user.name", "X"])
      File.write!(Path.join(other, "mix.exs"), "def project, do: [app: :something_else]\n")
      commit!(other, "first")

      assert_raise Mix.Error, ~r/Not a Kiln checkout/, fn ->
        run(other, ["--check"])
      end
    end

    test "a Kiln checkout with no release tags says so", %{tmp_dir: tmp_dir, clone: clone} do
      bare = Path.join(tmp_dir, "untagged")
      git!(tmp_dir, ["clone", "--quiet", clone, bare])
      for tag <- ["v0.1.0", "v0.2.0", "v1.0.0"], do: git!(bare, ["tag", "-d", tag])

      assert_raise Mix.Error, ~r/No release tags found upstream/, fn ->
        run(bare, ["--check", "--no-fetch"])
      end
    end
  end
end
