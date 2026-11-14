defmodule KilnCMS.Security.Posture.Checks.SecondFactorRequiredTest do
  @moduledoc """
  `core.second_factor_required` (#2252, #2247) against the site's real policy
  row and members: off is not applicable (an upgrade must not turn every
  site's posture to a warning), someone in their grace period warns, the same
  person enrolling or passing their deadline passes, and a policy that cannot
  be read is unknown rather than off. Each case turns the check on its own.
  """
  use KilnCMS.DataCase, async: true

  # The unreadable-row case logs the refused read on purpose.
  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.SecondFactorFixtures
  alias KilnCMS.Security.Posture.Checks.SecondFactorRequired

  @day 86_400

  setup do
    %{site: org("pfsfr")}
  end

  # The policy covered its tiers `days_ago` days before now.
  defp policy!(site, required_for, opts) do
    since = DateTime.add(DateTime.utc_now(), -Keyword.fetch!(opts, :days_ago) * @day, :second)

    SecondFactorFixtures.policy_row!(site, required_for,
      since: since,
      grace_days: Keyword.fetch!(opts, :grace_days)
    )
  end

  # A member whose account and membership both predate the policy.
  defp member(site, role) do
    user(:viewer, inserted_at: SecondFactorFixtures.long_ago())
    |> member!(site, role, inserted_at: SecondFactorFixtures.long_ago())
  end

  defp run(site, opts \\ []), do: SecondFactorRequired.run(context(site, opts))

  test "off is not applicable, with nothing counted", %{site: site} do
    _bare_admin = member(site, :admin)

    result = run(site)

    assert result.status == :n_a
    assert result.summary =~ "doesn't require two-step sign-in"
    assert result.fix_path == "/editor/two-factor"
    assert result.docs_url =~ "#two-step-sign-in-required"
    assert result.facts.required_for == "off"
    assert result.facts.covered == 0
    assert result.facts.admin_in_grace == nil
  end

  test "an explicit off row is not applicable either", %{site: site} do
    policy!(site, :off, days_ago: 30, grace_days: 14)
    assert %{status: :n_a} = run(site)
  end

  test "on with someone in their grace period warns, and passes once they enroll",
       %{site: site} do
    policy!(site, :admins, days_ago: 2, grace_days: 14)
    bare = member(site, :admin)

    result = run(site)

    assert result.status == :warn
    assert result.summary =~ "1 person hasn't set up two-step sign-in"
    assert result.facts.in_grace == 1
    assert result.facts.overdue == 0
    assert result.facts.admin_in_grace == 1
    assert result.facts.editor_in_grace == nil
    assert result.facts.earliest_deadline != nil

    deadline = DateTime.add(DateTime.utc_now(), 12 * @day, :second)
    assert result.summary =~ Calendar.strftime(deadline, "%Y-%m-%d")

    enrol_totp!(bare)

    result = run(site)
    assert result.status == :pass
    assert result.summary =~ "required for administrators"
    assert result.facts.in_grace == 0
    assert result.facts.enrolled == 1
    assert result.facts.earliest_deadline == nil
  end

  test "once the deadline passes it passes, and counts the person as overdue",
       %{site: site} do
    policy!(site, :admins, days_ago: 2, grace_days: 14)
    _bare = member(site, :admin)

    # Sixteen days on, their grace period has ended: they are held, not exposed.
    later = DateTime.add(DateTime.utc_now(), 16 * @day, :second)
    result = run(site, now: later)

    assert result.status == :pass
    assert result.facts.in_grace == 0
    assert result.facts.overdue == 1
    assert result.facts.admin_overdue == 1
  end

  test "in grace and overdue are told apart, per tier", %{site: site} do
    policy!(site, :editors, days_ago: 30, grace_days: 14)
    _overdue_admin = member(site, :admin)

    # A new member's grace starts with their membership.
    _new_editor = user(:viewer) |> member!(site, :editor)
    # Seeded enrolled: an overdue account must prove its email to enroll now.
    {enrolled, _secret} =
      KilnCMS.TwoFactorFixtures.enabled_user(
        role: :viewer,
        inserted_at: SecondFactorFixtures.long_ago()
      )

    _enrolled_editor =
      member!(enrolled, site, :editor, inserted_at: SecondFactorFixtures.long_ago())

    result = run(site)

    assert result.status == :warn
    assert result.facts.covered == 3
    assert result.facts.enrolled == 1
    assert result.facts.in_grace == 1
    assert result.facts.overdue == 1
    assert result.facts.admin_overdue == 1
    assert result.facts.admin_in_grace == 0
    assert result.facts.editor_in_grace == 1
    assert result.facts.editor_enrolled == 1
    assert result.facts.viewer_in_grace == nil
  end

  test "a tier the policy does not cover is not counted", %{site: site} do
    policy!(site, :admins, days_ago: 2, grace_days: 14)
    _editor = member(site, :editor)

    assert %{status: :pass, facts: %{covered: 0, editor_in_grace: nil}} = run(site)
  end

  test "a policy that cannot be read is unknown, not off", %{site: site} do
    policy!(site, :admins, days_ago: 2, grace_days: 14)
    _bare = member(site, :admin)

    result = KilnCMS.OrgSettings.with_actor(nil, fn -> run(site) end)

    assert result.status == :unknown
    assert result.fix_path == "/editor/two-factor"
  end

  test "facts are scalars, within the result's limit", %{site: site} do
    policy!(site, :everyone, days_ago: 2, grace_days: 14)
    _bare = member(site, :viewer)

    {:ok, %{facts: facts}} = Kiln.Security.Check.Result.sanitize(run(site))

    assert map_size(facts) == 16
    assert Enum.all?(Map.values(facts), &(is_nil(&1) or is_number(&1) or is_binary(&1)))
    assert facts["required_for"] == "everyone"
  end
end
