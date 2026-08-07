defmodule KilnCMS.Beta do
  @moduledoc """
  Operator-facing entry point for standing up a **beta testing round** — the
  "Before every round" checklist in `docs/beta-testing.md`, done mechanically.

  The one public call is `provision!/1`. It creates the tester seats at the
  tier the round shape needs, gives each tester their own content to break,
  reports the readiness of the infrastructure the session script touches, and
  records the commit the round is frozen at.

  It is guarded so a mistyped `DATABASE_URL` can't mint known-password accounts
  in production, then delegates the actual work to `KilnCMS.Beta.Round`.

  > #### It prints live credentials {: .warning}
  >
  > The handout is 1–13 working `:editor`/`:admin` passwords on stdout — that
  > is the deliverable, and there is no way to provision without it. Run it
  > from a terminal you'd read a credential in, **not** through a deployment
  > platform's one-off command runner, whose output is usually retained in a
  > log store indefinitely.

  ## Why it exists

  `docs/beta-testing.md` prescribes 4–6 testers per round on a ~1 week cadence.
  Provisioning them by hand means remembering that publishing is admin-only
  (so an authoring round stalls without a facilitator seat), and that an empty
  CMS "tests nothing but the empty states". Both are documented, and both were
  entirely manual. This is that checklist as code.
  """

  alias KilnCMS.Beta.Round
  alias KilnCMS.Repo

  # Mirrors `KilnCMS.Staging`: a round provisions accounts whose passwords are
  # printed to a terminal, so the target database name has to look like
  # somewhere that is acceptable. A beta deployment is a real deployment, so
  # the marker list is wider than the scrub's — but "kiln_prod" still refuses.
  @ephemeral_markers ~w(beta staging preview ephemeral tmp scratch dev test)

  @doc """
  Provision a beta round against the currently-connected database.

  Refuses unless the caller has clearly opted in. Prints the handout and a
  readiness report through `:shell` (default `IO.puts/1`) and returns the
  summary map.

  ## Options

    * `:confirm?` — must be truthy, or set `KILN_BETA_ROUND=confirm`. Without
      it the target is printed and nothing is created.
    * `:force?` — skip the database-name check (or `KILN_BETA_FORCE=true`;
      accepts any spelling `KilnCMS.Config.Env` recognizes).
    * `:shape` — `:authoring` (default) or `:operator`. Decides the tier
      testers get, and whether a facilitator admin seat is required.
    * `:testers` — how many tester seats to generate (default 4, max 12).
      Ignored when `:emails` is given.
    * `:emails` — explicit tester emails, one seat each. Use real addresses
      when testers need password reset to work. An address that already has an
      account here **adopts** it: the account's role is moved to the seat's
      tier (through `:manage_access`, so live sockets are evicted) and the
      handout says so loudly.
    * `:round` — round label used in generated emails and seeded slugs
      (default `"1"`). Re-running the same label is idempotent.
    * `:domain` — email domain for generated seats (default `"beta.kiln.test"`).
    * `:facilitator_email` — the admin seat (default `beta-facilitator@<domain>`).
    * `:reset_passwords?` — re-issue passwords for seats that already exist.
      Off by default: a round in flight must not have its testers locked out.
    * `:seed?` — seed each tester content to break (default `true`).
    * `:shell` — 1-arity logger for human output (default `&IO.puts/1`).
  """
  @spec provision!(keyword()) :: Round.summary()
  def provision!(opts \\ []) do
    shell = Keyword.get(opts, :shell, &IO.puts/1)
    {host, database} = Repo.target()

    # KILN_BETA_ROUND is a sentinel word, not a boolean — typing `true` must not
    # confirm. KILN_BETA_FORCE *is* a boolean, so it goes through the shared
    # spelling table (#606/#607) rather than growing a private one.
    confirmed? = Keyword.get(opts, :confirm?) || env_sentinel?("KILN_BETA_ROUND", "confirm")
    forced? = Keyword.get(opts, :force?) || KilnCMS.Config.Env.flag("KILN_BETA_FORCE", false)

    shell.("Target database: #{database}@#{host}")

    unless confirmed? do
      raise """
      Refusing to provision a beta round without explicit confirmation.

      This creates accounts with printed passwords in #{database}@#{host}.
      Confirm you mean this database (NOT production) with `--yes`
      (mix) or `KILN_BETA_ROUND=confirm`.
      """
    end

    unless forced? or acceptable_target?(database) do
      raise """
      Refusing to provision into #{inspect(database)}: its name doesn't look
      like a beta/staging database.

      A beta database name should have one of these as a word: #{Enum.join(@ephemeral_markers, ", ")}.
      If this really is the beta deployment, re-run with `--force`
      (mix) or `KILN_BETA_FORCE=true`.
      """
    end

    # The handout prints from `:on_seats` — the moment the accounts exist and
    # before any seeding runs. A generated password lives nowhere but that
    # callback's argument, so printing it only after `run/1` returned meant any
    # raise during seeding left live accounts nobody could sign in to, whose
    # only remedy (`--reset-passwords`) is the one thing you must not do to a
    # round already in session.
    summary = Round.run(Keyword.put(opts, :on_seats, &shell.(handout(&1))))

    shell.(readiness(summary))
    shell.(next_steps(summary))
    summary
  end

  @doc """
  The commit the round is frozen at, as `{sha, dirty?}`, or `:unknown` outside
  a git checkout (a release, say).

  `docs/beta-testing.md` asks the facilitator to record this and hand it to
  testers, so a finding can be tied to what was actually tested. `dirty?` is
  reported because a round frozen against uncommitted changes cannot be.
  """
  @spec frozen_commit() :: {String.t(), boolean()} | :unknown
  def frozen_commit do
    with {sha, 0} <- System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true),
         {status, 0} <- System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {String.trim(sha), String.trim(status) != ""}
    else
      _ -> :unknown
    end
  rescue
    # `git` absent entirely — an unknown commit, not a failed round.
    ErlangError -> :unknown
  end

  # The one artifact the facilitator actually hands out. Passwords for seats
  # created (or reset) in *this* run only — an existing seat's password is not
  # recoverable, which is why `--reset-passwords` exists.
  #
  # Takes `t:KilnCMS.Beta.Round.seats/0`, not the full summary, because it is
  # called before the seeding that produces the rest of the summary.
  defp handout(seats) do
    rows = Enum.map_join(seats.seats, "\n", &seat_row/1)

    adopted =
      case Enum.filter(seats.seats, & &1.adopted_from) do
        [] ->
          ""

        adopted ->
          # Loud, because `--tester` takes real addresses: an operator round
          # aimed at somebody who already has an account here re-tiers them to
          # :admin, and nothing else on this page would say so.
          "\n\n  Re-tiered #{length(adopted)} EXISTING account(s): " <>
            Enum.map_join(adopted, ", ", &"#{&1.email} (#{&1.adopted_from} → #{&1.role})") <>
            "\n  These were not created by this round. Restore their role when it ends."
      end

    """

    Round #{seats.round} — #{seats.shape} shape, #{length(seats.seats)} seat(s)
    #{String.duplicate("-", 72)}
    #{rows}#{adopted}

    Passwords are shown once. Hand them out over a channel you'd hand out any
    other credential over, and re-run with `--reset-passwords` if one is lost.\
    """
  end

  defp seat_row(seat) do
    password = seat.password || "(unchanged — re-issue with --reset-passwords)"

    "  #{String.pad_trailing(to_string(seat.email), 38)} #{String.pad_trailing(to_string(seat.role), 8)} #{password}"
  end

  defp readiness(summary) do
    lines =
      Enum.map_join(summary.readiness, "\n", fn {label, status, detail} ->
        "  [#{if status == :ok, do: "ok", else: "!!"}] #{String.pad_trailing(label, 24)} #{detail}"
      end)

    """

    Readiness
    #{String.duplicate("-", 72)}
    #{lines}\
    """
  end

  defp next_steps(summary) do
    seeded =
      if summary.seeded == 0 do
        "  Nothing was seeded — testers will only see empty states. Re-run without `--no-seed`."
      else
        "  Seeded #{summary.seeded} record(s) across #{length(summary.testers)} tester(s)."
      end

    """

    Next
    #{String.duplicate("-", 72)}
    #{seeded}
      Ensure the `beta` label exists (GitHub silently drops labels an issue form
      references but the repo doesn't define):

        gh label create beta --color 0E8A16 \\
          --description "Sourced from a beta testing session"

      Then run the scenarios in docs/beta-testing.md and triage within ~24h.\
    """
  end

  @doc """
  Whether a database name is somewhere a round may mint known-password seats.

  A marker has to appear as a **word** — separated by anything that isn't
  alphanumeric, or at either end. A bare substring test is what lets
  `kiln_latest` through on `test` and `devices_live` through on `dev`, and this
  guard is widest exactly where being wrong is worst: unlike a staging scrub, a
  beta deployment is a real one with real accounts already in it.

  Public so the guard can be exercised without a second database: the suite's
  own name always satisfies it, which would leave the refusal path untested.
  """
  @spec acceptable_target?(String.t()) :: boolean()
  def acceptable_target?(database) do
    database
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.any?(&(&1 in @ephemeral_markers))
  end

  defp env_sentinel?(var, sentinel) do
    case System.get_env(var) do
      nil -> false
      value -> String.downcase(String.trim(value)) == sentinel
    end
  end
end
