defmodule Mix.Tasks.Kiln.Beta.Round do
  @shortdoc "Provision a beta testing round: seats, seed content, readiness"

  @moduledoc """
  Run the "Before every round" checklist in `docs/beta-testing.md`.

  Creates the tester seats the round shape needs, gives each tester their own
  content to break, reports whether the infrastructure the session script
  touches is actually up, and records the commit the round is frozen at.

  **Creates accounts and prints their passwords** — it refuses without `--yes`
  and unless the target database name looks like a beta/staging one. Run it from
  a terminal you'd read a credential in, not through a deployment platform's
  one-off command runner, whose output is usually retained.

  ```bash
  mix kiln.beta.round --yes --shape authoring --testers 4 --round 1
  ```

  Idempotent by email and slug: re-run it to add a fifth tester mid-round
  without disturbing the four already in a session.

  ## Options

    * `--yes` — confirm you mean this database (required).
    * `--force` — skip the database-name safety check.
    * `--shape` — `authoring` (default) or `operator`. An authoring round gets
      `editor` testers plus one `admin` facilitator seat, because publishing is
      an admin approval step and the scenarios stall without one. An operator
      round is admin-tiered throughout.
    * `--testers` — how many tester seats (default 4, max 12). The doc's
      recommended round is 4–6.
    * `--tester <email>` — repeatable; use real addresses instead of generated
      ones. Replaces `--testers`. An address that already has an account here
      **adopts** it — the account is moved to the seat's tier and the handout
      says so loudly, so you know to put it back when the round ends.
    * `--round` — round label, used in generated emails and seeded slugs
      (default `1`).
    * `--domain` — email domain for generated seats (default `beta.kiln.test`).
    * `--facilitator-email` — the admin seat for an authoring round.
    * `--reset-passwords` — re-issue passwords for seats that already exist,
      revoking the old credential's tokens and dropping its live sockets.
    * `--no-seed` — skip the per-tester content. Testers then see empty states
      only, which is rarely what a round wants to test.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _positional} =
      OptionParser.parse!(argv,
        strict: [
          yes: :boolean,
          force: :boolean,
          shape: :string,
          testers: :integer,
          tester: :keep,
          round: :string,
          domain: :string,
          facilitator_email: :string,
          reset_passwords: :boolean,
          seed: :boolean
        ]
      )

    emails = for {:tester, email} <- opts, do: email

    KilnCMS.Beta.provision!(
      confirm?: opts[:yes],
      force?: opts[:force],
      shape: opts[:shape] || :authoring,
      testers: opts[:testers] || 4,
      emails: if(emails == [], do: nil, else: emails),
      round: opts[:round] || "1",
      domain: opts[:domain] || "beta.kiln.test",
      facilitator_email: opts[:facilitator_email],
      reset_passwords?: opts[:reset_passwords] || false,
      seed?: Keyword.get(opts, :seed, true),
      shell: fn message -> Mix.shell().info(message) end
    )
  end
end
