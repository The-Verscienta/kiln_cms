defmodule Mix.Tasks.Kiln.Update do
  @shortdoc "Move a project's pinned Kiln core to a newer upstream release"

  @moduledoc """
  Updates a downstream project's pinned Kiln core.

  A project layers its own `projects/<name>/` overlay onto this repo and pins
  it as a git submodule at `kiln/upstream` (see `projects/README.md`). Updating
  Kiln therefore means moving that pin to a newer tag, rebuilding the image,
  and running the migrations the new version brings — this task does the first
  part and tells you precisely what the rest is.

  Run it from inside the submodule:

      cd kiln/upstream
      mix kiln.update --check     # report only, change nothing
      mix kiln.update             # move the pin to the latest release

  ## What it refuses to do

  It stops rather than guess when the update isn't a clean fast-forward:

    * the submodule has uncommitted changes — stash or commit them first;
    * the pin has local commits not in upstream (you've patched the core) —
      `--force` proceeds and leaves you to resolve the divergence yourself;
    * the target is a **major** version ahead, which by this repo's versioning
      means the overlay contract broke and your subproject needs code changes —
      `--allow-major` proceeds after you've read the upgrade notes.

  It never runs migrations, rebuilds an image, or deploys. Those touch a live
  database and a live site, so they stay explicit steps you run yourself; the
  task prints them in order when it finishes.

  ## Options

    * `--check` — report what an update would do and exit without changing
      anything. Exits 0 whether or not an update is available.
    * `--exit-code` — with `--check`, exit 1 when an update *is* available, so
      CI can fail a "you're behind upstream" check.
    * `--to VERSION` — target a specific release (`--to v0.3.0`) instead of the
      newest one.
    * `--ref REF` — target an arbitrary git ref (`--ref main`, `--ref a1b2c3d`)
      instead of a release tag. Skips version comparison and upgrade notes;
      for tracking bleeding edge deliberately.
    * `--allow-major` — permit a major-version jump.
    * `--force` — proceed even though the pin has diverged from upstream.
    * `--no-fetch` — skip `git fetch`; compare against already-fetched refs.

  ## Exit status

  Non-zero on any refusal, so a scripted update halts instead of continuing to
  the rebuild step with an unchanged pin.
  """

  use Mix.Task

  # Deliberately empty: an update must work even when the currently pinned
  # core doesn't compile — that's often *why* you're updating.
  @requirements []

  @tag_pattern "v*"

  @switches [
    check: :boolean,
    exit_code: :boolean,
    to: :string,
    ref: :string,
    allow_major: :boolean,
    force: :boolean,
    fetch: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    repo = locate_repo!()
    unless opts[:fetch] == false, do: fetch!(repo)

    current = current_pin(repo)
    target = resolve_target!(repo, opts)

    if current.sha == target.sha do
      Mix.shell().info([
        :green,
        "Already up to date",
        :reset,
        " - pinned at #{describe(target)}."
      ])
    else
      report = report(repo, current, target)
      proceed(repo, current, target, {report, opts})
    end
  end

  # The guards only gate *changing* the pin. --check promises to report and
  # change nothing, so it must not fail on a dirty tree or a major jump —
  # those are exactly what you run --check to find out about.
  defp proceed(repo, current, target, {report, opts}) do
    if opts[:check] do
      finish_check(opts)
    else
      guard!(repo, current, target, opts)
      check_report_complete!(report, opts)
      apply_update!(repo, target)
      print_next_steps(repo, target)
    end
  end

  defp check_report_complete!(:ok, _opts), do: :ok

  # An incomplete report means the safety information the operator would act on
  # never got printed. Moving the pin anyway hands them a silent update.
  defp check_report_complete!({:incomplete, missing}, opts) do
    unless opts[:force] do
      Mix.raise("""
      Could not determine #{Enum.join(missing, " or ")} for this update.

      That usually means a shallow clone: the commit range between the current
      pin and the target isn't fully present locally. Fetch full history first:

          git fetch --unshallow origin

      Updating without that report would skip the backup and upgrade-step
      warnings this task exists to surface. Re-run with --force to proceed
      anyway.
      """)
    end
  end

  defp finish_check(opts) do
    Mix.shell().info("\nRun without --check to move the pin.")
    if opts[:exit_code], do: exit({:shutdown, 1})
  end

  # ---- git context -------------------------------------------------------

  # The task has to work from the submodule but report against the
  # superproject, since the pin lives in the *parent* repo's index.
  defp locate_repo! do
    root = git!(".", ~w[rev-parse --show-toplevel])

    superproject =
      case git(".", ~w[rev-parse --show-superproject-working-tree]) do
        {:ok, ""} -> nil
        {:ok, path} -> path
        {:error, _} -> nil
      end

    if is_nil(superproject) do
      Mix.shell().info([
        :yellow,
        "Note: ",
        :reset,
        "this checkout isn't a submodule of a project repo, so there's no pin\n",
        "to update. Moving the checkout itself instead - this is what you want\n",
        "when developing Kiln, not when running a site built on it.\n"
      ])
    end

    %{root: root, superproject: superproject}
  end

  defp fetch!(repo) do
    Mix.shell().info("Fetching upstream releases...")
    git!(repo.root, ~w[fetch origin --tags --prune])
  end

  defp current_pin(repo) do
    sha = git!(repo.root, ~w[rev-parse HEAD])

    version =
      case git(repo.root, ["describe", "--tags", "--exact-match", sha]) do
        {:ok, tag} -> parse_version(tag)
        {:error, _} -> nil
      end

    %{sha: sha, tag: version && "v#{version}", version: version}
  end

  # ---- target resolution -------------------------------------------------

  defp resolve_target!(repo, opts) do
    cond do
      ref = opts[:ref] ->
        sha = rev_parse!(repo, ref, "unknown ref")
        %{sha: sha, tag: ref, version: nil}

      to = opts[:to] ->
        tag = normalize_tag(to)

        version =
          parse_version(tag) ||
            Mix.raise("--to expects a release like v0.3.0, got #{inspect(to)}")

        sha = rev_parse!(repo, tag, "no such release")
        %{sha: sha, tag: tag, version: version}

      true ->
        latest_release!(repo)
    end
  end

  defp rev_parse!(repo, ref, message) do
    case git(repo.root, ["rev-parse", "--verify", "#{ref}^{commit}"]) do
      {:ok, sha} -> sha
      {:error, _} -> Mix.raise("#{message}: #{ref}")
    end
  end

  defp latest_release!(repo) do
    tags =
      repo.root
      |> git!(["tag", "--list", @tag_pattern])
      |> String.split("\n", trim: true)
      |> Enum.map(&{&1, parse_version(&1)})
      |> Enum.reject(fn {_tag, version} -> is_nil(version) end)

    if tags == [] do
      Mix.raise("""
      No release tags found upstream.

      This repo tags releases as v0.1.0, v0.2.0, ... If you expected tags here,
      the remote may not have been fetched — re-run without --no-fetch.
      """)
    end

    {tag, version} = Enum.max_by(tags, fn {_tag, version} -> version end, Version)

    %{sha: rev_parse!(repo, tag, "unresolvable tag"), tag: tag, version: version}
  end

  defp normalize_tag("v" <> _ = tag), do: tag
  defp normalize_tag(version), do: "v" <> version

  defp parse_version("v" <> version), do: parse_version(version)

  defp parse_version(version) do
    case Version.parse(version) do
      {:ok, parsed} -> parsed
      :error -> nil
    end
  end

  # ---- reporting ---------------------------------------------------------

  defp report(repo, current, target) do
    Mix.shell().info([
      "\n",
      :bright,
      "#{describe(current)} -> #{describe(target)}",
      :reset
    ])

    range = "#{current.sha}..#{target.sha}"

    case git(repo.root, ["rev-list", "--count", range]) do
      {:ok, count} -> Mix.shell().info("#{count} commit(s) upstream.")
      {:error, _} -> :ok
    end

    # Both halves report whether they could actually answer. A git failure here
    # (typically a shallow submodule clone, where the old..new range isn't in
    # the local object store) must never read as "nothing to worry about" —
    # that's how an operator skips a backup and boots into a destructive
    # migration, since the Dockerfile CMD migrates unconditionally.
    [report_migrations(repo, range), report_upgrade_notes(repo, current, target)]
    |> Enum.filter(&match?({:unknown, _}, &1))
    |> case do
      [] -> :ok
      unknowns -> {:incomplete, Enum.map(unknowns, fn {:unknown, what} -> what end)}
    end
  end

  # New migration files are the part of an update that touches live data, so
  # they get named individually rather than counted.
  defp report_migrations(repo, range) do
    case git(repo.root, [
           "diff",
           "--name-only",
           "--diff-filter=A",
           range,
           "--",
           "priv/repo/migrations"
         ]) do
      {:ok, ""} ->
        Mix.shell().info("No new migrations.")
        :ok

      {:ok, out} ->
        files = String.split(out, "\n", trim: true)
        Mix.shell().info([:yellow, "\n#{length(files)} new migration(s):", :reset])
        Enum.each(files, &Mix.shell().info("  #{Path.basename(&1)}"))
        Mix.shell().info("Back up before deploying: scripts/backup.sh")
        :ok

      {:error, reason} ->
        Mix.shell().error("\nCould not list new migrations: #{reason}")
        {:unknown, "new migrations"}
    end
  end

  # The changelog at the *target* ref is authoritative — it documents its own
  # release, which the currently pinned copy by definition can't.
  defp report_upgrade_notes(_repo, _current, %{version: nil}), do: :ok

  defp report_upgrade_notes(repo, current, target) do
    case git(repo.root, ["show", "#{target.sha}:CHANGELOG.md"]) do
      {:ok, changelog} ->
        print_upgrade_notes(upgrade_notes(changelog, current.version, target.version))
        :ok

      {:error, reason} ->
        Mix.shell().error("\nCould not read CHANGELOG.md at #{target.tag}: #{reason}")
        {:unknown, "upgrade notes"}
    end
  end

  defp print_upgrade_notes([]), do: :ok

  defp print_upgrade_notes(notes) do
    Mix.shell().info([:yellow, "\nUpgrade notes:", :reset])
    Enum.each(notes, &print_upgrade_note/1)
  end

  defp print_upgrade_note({version, body}) do
    Mix.shell().info([:bright, "\n  #{version}", :reset])
    body |> String.split("\n") |> Enum.each(&Mix.shell().info("  #{&1}"))
  end

  @doc false
  # Extracts each `### Upgrading` block for releases in (from, to]. Public only
  # so it can be tested against changelog fixtures without shelling out to git.
  def upgrade_notes(changelog, from, to) do
    changelog
    |> String.split(~r/^## /m, trim: true)
    |> Enum.flat_map(fn section ->
      with [heading | _] <- String.split(section, "\n", parts: 2),
           %Version{} = version <- section_version(heading),
           true <- in_range?(version, from, to),
           [_, body] <- String.split(section, ~r/^### Upgrading\s*$/m, parts: 2) do
        # Stop at the next h3 so a following "### Fixed" isn't read as advice.
        [{version, body |> String.split(~r/^### /m, parts: 2) |> hd() |> String.trim()}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {version, _} -> version end, Version)
  end

  defp section_version(heading) do
    case Regex.run(~r/\[?v?(\d+\.\d+\.\d+)\]?/, heading) do
      [_, version] -> parse_version(version)
      _ -> nil
    end
  end

  # `from` is nil when the current pin isn't on a tag — an untagged pin has no
  # reliable lower bound, so every note up to the target is shown.
  defp in_range?(version, nil, to), do: Version.compare(version, to) != :gt

  defp in_range?(version, from, to) do
    Version.compare(version, from) == :gt and Version.compare(version, to) != :gt
  end

  defp describe(%{tag: nil, sha: sha}), do: String.slice(sha, 0, 7)
  defp describe(%{tag: tag, sha: sha}), do: "#{tag} (#{String.slice(sha, 0, 7)})"

  # ---- guards ------------------------------------------------------------

  defp guard!(repo, current, target, opts) do
    check_clean!(repo)
    check_diverged!(repo, current, target, opts)
    check_major!(current, target, opts)
  end

  defp check_clean!(repo) do
    case git!(repo.root, ~w[status --porcelain]) do
      "" ->
        :ok

      changes ->
        Mix.raise("""
        The Kiln checkout has uncommitted changes:

        #{changes}

        Updating would discard or conflict with them. Commit or stash first.
        """)
    end
  end

  # A pin ahead of upstream means the core was patched locally. Checking out a
  # tag would silently strand those commits, so it takes --force.
  defp check_diverged!(repo, current, target, opts) do
    unless opts[:force], do: do_check_diverged!(repo, current, target)
  end

  defp do_check_diverged!(repo, current, target) do
    ahead =
      case git(repo.root, ["rev-list", "--count", "#{target.sha}..#{current.sha}"]) do
        {:ok, count} ->
          String.to_integer(count)

        # Fail closed: a failure here (no common history in a shallow clone)
        # means we cannot tell whether local core commits would be stranded,
        # and checking out the target would silently strand them.
        {:error, reason} ->
          Mix.raise("""
          Could not compare the current pin against #{target.tag}: #{reason}

          Without that comparison this task can't tell whether the pinned core
          carries local commits that an update would strand. Fetch full history
          (git fetch --unshallow origin) and re-run, or pass --force to skip
          the check.
          """)
      end

    if ahead > 0 do
      Mix.raise("""
      The pinned core has #{ahead} commit(s) not in #{target.tag}.

      Local changes to the core don't survive an update, and they're a sign the
      change belongs in an overlay (projects/<name>/) or upstream instead. See
      projects/README.md.

      Re-run with --force to check out #{target.tag} anyway, leaving those
      commits reachable only by SHA.
      """)
    end
  end

  defp check_major!(%{version: %Version{} = from}, %{version: %Version{} = to}, opts) do
    if to.major > from.major and !opts[:allow_major] do
      Mix.raise("""
      #{from} -> #{to} is a major-version update.

      In this repo that specifically means the overlay contract broke: your
      projects/ subproject needs code changes before it will compile against
      the new core. Read the upgrade notes above, then re-run with
      --allow-major.
      """)
    end
  end

  # An untagged pin has no major version to compare, so the guard above can't
  # run. That is exactly the first-update case CHANGELOG.md describes ("if your
  # project pins a SHA from before this tag"), so it fails closed rather than
  # waving through what might be a contract-breaking jump.
  defp check_major!(%{version: nil}, %{version: %Version{} = to}, opts) do
    unless opts[:allow_major] do
      Mix.raise("""
      The current pin isn't on a release tag, so this task can't tell whether
      #{to} is a major-version jump from it.

      A major update means the overlay contract broke and your projects/
      subproject needs code changes. Read the upgrade notes above, then re-run
      with --allow-major to confirm you've accounted for that.
      """)
    end
  end

  defp check_major!(_current, _target, _opts), do: :ok

  # ---- apply -------------------------------------------------------------

  defp apply_update!(repo, target) do
    Mix.shell().info("\nChecking out #{describe(target)}...")
    git!(repo.root, ["checkout", "--detach", target.sha])
    Mix.shell().info([:green, "Pin moved.", :reset])
  end

  defp print_next_steps(repo, target) do
    submodule_path =
      if repo.superproject, do: Path.relative_to(repo.root, repo.superproject), else: nil

    steps =
      List.flatten([
        if submodule_path do
          [
            "cd #{repo.superproject}",
            "git add #{submodule_path}",
            "git commit -m \"chore: update kiln to #{target.tag}\""
          ]
        else
          []
        end,
        "mix deps.get",
        "# rebuild and redeploy your image, then verify migrations ran"
      ])

    Mix.shell().info([:bright, "\nNext steps:", :reset])
    Enum.each(steps, &Mix.shell().info("  #{&1}"))

    Mix.shell().info("""

    Migrations run on boot (see the Dockerfile CMD), so deploying the rebuilt
    image applies them. Take a backup first if the report above listed any.
    """)
  end

  # ---- git plumbing ------------------------------------------------------

  defp git!(dir, args) do
    case git(dir, args) do
      {:ok, out} -> out
      {:error, out} -> Mix.raise("git #{Enum.join(args, " ")} failed:\n#{out}")
    end
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _status} -> {:error, String.trim(out)}
    end
  end
end
