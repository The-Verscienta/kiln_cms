defmodule KilnCMS.Security.Posture.Checks.SecondFactorTest do
  @moduledoc """
  `core.second_factor` (#2252) against real accounts and memberships: a site
  where everyone enrolled passes, and each single change below turns it.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.Security.Posture.Checks.SecondFactor

  setup do
    site = org("pf2")
    # A membership admin whose own account is a viewer (B3), and an editor.
    admin = user(:viewer) |> member!(site, :admin) |> enrol_totp!()
    editor = user(:viewer) |> member!(site, :editor) |> enrol_totp!()
    %{site: site, admin: admin, editor: editor}
  end

  test "passes when every admin and editor enrolled", %{site: site} do
    result = SecondFactor.run(context(site))

    assert result.status == :pass
    assert result.facts == %{admins: 1, editors: 1, admins_without: 0, editors_without: 0}
    assert result.details == []
    assert result.fix_path == "/editor/settings"
  end

  test "fails for a membership admin without one, and names them", %{site: site} do
    bare = user(:viewer) |> member!(site, :admin)

    result = SecondFactor.run(context(site))

    assert result.status == :fail
    assert result.summary =~ "1 administrator has no authenticator app"
    assert result.summary =~ "passkey"
    assert result.details == [to_string(bare.email)]
    assert result.facts.admins_without == 1
    assert result.facts.admins == 2
  end

  test "warns when only an editor has none", %{site: site} do
    bare = user(:viewer) |> member!(site, :editor)

    result = SecondFactor.run(context(site))

    assert result.status == :warn
    assert result.details == [to_string(bare.email)]
    assert result.facts.editors_without == 1
  end

  test "an admin and an editor are each counted once, on their own tier", %{site: site} do
    # The legacy branch (a membership-less editor) applies to the default org
    # only, so on this site only memberships count.
    _elsewhere = user(:editor)

    result = SecondFactor.run(context(site))
    assert result.facts.admins == 1
    assert result.facts.editors == 1
  end

  describe "is not turned by" do
    test "a platform admin without one: the deployment check reports them", %{site: site} do
      _platform = user(:admin)
      _platform_member = user(:admin) |> member!(site, :admin)

      assert %{status: :pass, facts: %{admins: 1}} = SecondFactor.run(context(site))
    end

    test "an erased account", %{site: site} do
      user(:viewer, anonymized_at: DateTime.utc_now()) |> member!(site, :admin)

      assert %{status: :pass} = SecondFactor.run(context(site))
    end

    test "a registration not approved, or rejected", %{site: site} do
      user(:viewer) |> member!(site, :admin, status: :pending)
      user(:viewer) |> member!(site, :editor, status: :rejected)

      assert %{status: :pass} = SecondFactor.run(context(site))
    end

    test "an admin of another site" do
      other = org("pf2-other")
      user(:viewer) |> member!(other, :admin)
      site = org("pf2-empty")

      assert %{status: :n_a} = SecondFactor.run(context(site))
      assert %{status: :fail} = SecondFactor.run(context(other))
    end
  end

  test "lists nine names and how many more", %{site: site} do
    for _ <- 1..12, do: user(:viewer) |> member!(site, :editor)

    result = SecondFactor.run(context(site))

    assert result.status == :warn
    assert length(result.details) == 10
    assert List.last(result.details) == "and 3 more"
  end
end
