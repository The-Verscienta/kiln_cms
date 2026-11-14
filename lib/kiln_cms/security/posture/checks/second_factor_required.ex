defmodule KilnCMS.Security.Posture.Checks.SecondFactorRequired do
  @moduledoc """
  `core.second_factor_required` (#2252, #2247): whether the site requires
  two-step sign-in (`KilnCMS.CMS.SiteSecondFactorPolicy`), and who it covers
  that has not set it up yet.

    * The policy cannot be read — `unknown`, never "off". Enforcement fails
      open to off there; this check must not report a requirement it cannot
      see as one that is unset.
    * Off — `n_a`. A site that has never turned the requirement on is not
      warned about it: `core.second_factor` already reports who has no
      authenticator app, and an upgrade must not turn every site's overall
      result (and every `GET /api/security/posture` monitor) to a warning.
    * On, and someone covered is still in their grace period — `warn`. That
      is what respecting the grace period means: until their deadline they
      can still sign in with a password alone.
    * On otherwise — `pass`. People past their deadline are held at sign-in
      until they set it up, so they are not exposed; they are counted in the
      facts (`overdue`) for whoever wants to chase them.

  The counts are `KilnCMS.Accounts.TwoFactorRequirement.roster/3`, the same
  the policy page shows. It reads the roster unauthorized, so a lost grant
  can never filter it to nobody, and raises on a failed read rather than
  answering zeros: the runner reports that as "could not run", never as a
  pass.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Security.Posture

  # Each tier's roster count and the fact it is published as.
  @tier_facts [
    {:admin, :enrolled, :admin_enrolled},
    {:admin, :in_grace, :admin_in_grace},
    {:admin, :overdue, :admin_overdue},
    {:editor, :enrolled, :editor_enrolled},
    {:editor, :in_grace, :editor_in_grace},
    {:editor, :overdue, :editor_overdue},
    {:viewer, :enrolled, :viewer_enrolled},
    {:viewer, :in_grace, :viewer_in_grace},
    {:viewer, :overdue, :viewer_overdue}
  ]

  @impl Kiln.Security.Check
  def id, do: "core.second_factor_required"

  @impl Kiln.Security.Check
  def title, do: gettext("Two-step sign-in required")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "Whether this site makes people set up two-step sign-in, and who it covers that hasn't yet."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def timeout, do: 3000

  @impl Kiln.Security.Check
  def run(%{org_id: org_id} = context) do
    opts = [
      fix_path: "/editor/two-factor",
      docs_url: Posture.docs_url("two-step-sign-in-required")
    ]

    case TwoFactorRequirement.read_policy(org_id) do
      :error ->
        unknown(gettext("The site's two-step sign-in requirement could not be read."), opts)

      {:ok, %{required_for: :off} = policy} ->
        n_a(
          gettext("This site doesn't require two-step sign-in."),
          Keyword.put(opts, :facts, facts(policy, %{}))
        )

      {:ok, policy} ->
        roster = TwoFactorRequirement.roster(org_id, policy, now: now(context))
        required(policy, roster, Keyword.put(opts, :facts, facts(policy, roster)))
    end
  end

  defp required(policy, roster, opts) do
    in_grace = sum(roster, :in_grace)

    if in_grace > 0 do
      warn(
        ngettext(
          "%{count} person hasn't set up two-step sign-in yet. It's enforced for them from %{date}.",
          "%{count} people haven't set up two-step sign-in yet. The first deadline is %{date}.",
          in_grace,
          date: date(earliest_deadline(roster))
        ),
        opts
      )
    else
      pass(required_for(policy.required_for), opts)
    end
  end

  defp required_for(:admins),
    do: gettext("Two-step sign-in is required for administrators.")

  defp required_for(:editors),
    do: gettext("Two-step sign-in is required for editors and administrators.")

  defp required_for(:everyone),
    do: gettext("Two-step sign-in is required for everyone on this site.")

  # Scalars only (`Kiln.Security.Check.Result`): the totals, then each tier's,
  # `nil` for a tier the policy does not cover.
  defp facts(policy, roster) do
    totals = %{
      required_for: Atom.to_string(policy.required_for),
      grace_days: policy.grace_days,
      covered: sum(roster, :total),
      enrolled: sum(roster, :enrolled),
      in_grace: sum(roster, :in_grace),
      overdue: sum(roster, :overdue),
      earliest_deadline: iso(earliest_deadline(roster))
    }

    for {tier, key, fact} <- @tier_facts, into: totals do
      {fact, get_in(roster, [tier, key])}
    end
  end

  defp sum(roster, key), do: roster |> Map.values() |> Enum.map(& &1[key]) |> Enum.sum()

  defp earliest_deadline(roster) do
    case roster |> Map.values() |> Enum.map(& &1.earliest_deadline) |> Enum.reject(&is_nil/1) do
      [] -> nil
      deadlines -> Enum.min(deadlines, DateTime)
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp now(%{now: %DateTime{} = now}), do: now
  defp now(_context), do: DateTime.utc_now()
end
