defmodule KilnCMS.Security.Posture.Checks.OperatorSecondFactorTest do
  @moduledoc """
  `core.operator_second_factor` (#2252): every platform administrator, by
  effective role (a live grant counts, an expired one does not), against real
  enrolments.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.PostureFixtures

  alias KilnCMS.Security.Posture.Checks.OperatorSecondFactor

  test "is not applicable with no platform administrator" do
    _site_admin = user(:editor)
    assert %{status: :n_a} = OperatorSecondFactor.run(context(nil))
  end

  test "passes when every platform administrator enrolled, and fails for one who did not" do
    user(:admin) |> enrol_totp!()
    assert %{status: :pass, facts: %{platform_admins: 1}} = OperatorSecondFactor.run(context(nil))

    bare = user(:admin)
    result = OperatorSecondFactor.run(context(nil))

    assert result.status == :fail
    assert result.details == [to_string(bare.email)]
    assert result.facts == %{platform_admins: 2, platform_admins_without: 1}
  end

  test "counts a live temporary grant, and not an expired one" do
    user(:admin) |> enrol_totp!()

    expired =
      user(:editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60)
      )

    assert %{status: :pass} = OperatorSecondFactor.run(context(nil))

    live =
      user(:editor,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    result = OperatorSecondFactor.run(context(nil))
    assert result.status == :fail
    assert result.details == [to_string(live.email)]
    refute to_string(expired.email) in result.details
  end

  test "an erased platform administrator is not counted" do
    user(:admin) |> enrol_totp!()
    user(:admin, anonymized_at: DateTime.utc_now())

    assert %{status: :pass, facts: %{platform_admins: 1}} = OperatorSecondFactor.run(context(nil))
  end
end
