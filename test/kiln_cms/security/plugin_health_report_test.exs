defmodule KilnCMS.Security.PluginHealthReportTest do
  @moduledoc """
  `KilnCMS.Security.PluginHealthReport` (#2571): who may read the installed
  plugins' cached health (platform administrators, a live grant included),
  who is refused (site administrators, an expired grant, a drafts-only key,
  nobody), and that a cold cache answers `nil` without warming it.

  `async: false`: the health cache is `:persistent_term`, and the check's
  switch is application env.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.Report
  alias KilnCMS.Security

  setup do
    health = Application.get_env(:kiln_cms, Health, [])
    Health.clear_cache()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Health, health)
      Health.clear_cache()
    end)

    %{site: org("phrep"), health: health}
  end

  defp read(actor, opts \\ []), do: Security.cached_plugin_health(%{}, [actor: actor] ++ opts)

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # An actor as `ApiKeyAuth` hands it over for a `:draft_write` key.
  defp with_draft_write_key(user) do
    user
    |> Ash.Resource.put_metadata(:using_api_key?, true)
    |> Ash.Resource.put_metadata(:api_key, %KilnCMS.Accounts.ApiKey{access: :draft_write})
  end

  describe "is allowed to" do
    test "a platform administrator" do
      assert {:ok, %Report{state: :disabled}} = read(user(:admin))
    end

    test "a platform editor holding a live admin grant" do
      actor = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(3600)})
      assert {:ok, %Report{}} = read(actor)
    end
  end

  describe "is refused to" do
    test "no actor" do
      assert {:error, %Ash.Error.Forbidden{}} = read(nil)
    end

    test "a platform editor whose admin grant has expired" do
      actor = user(:editor, %{granted_role: :admin, granted_role_expires_at: later(-1)})
      assert {:error, %Ash.Error.Forbidden{}} = read(actor)
    end

    for role <- [:editor, :viewer] do
      test "a platform #{role}" do
        assert {:error, %Ash.Error.Forbidden{}} = read(user(unquote(role)))
      end
    end

    test "a site administrator, with or without the site as tenant", %{site: site} do
      admin = user(:viewer) |> member!(site, :admin)

      assert {:error, %Ash.Error.Forbidden{}} = read(admin)
      assert {:error, %Ash.Error.Forbidden{}} = read(admin, tenant: site.id)
    end

    test "a platform administrator's draft_write key" do
      assert {:error, %Ash.Error.Forbidden{}} = read(with_draft_write_key(user(:admin)))
    end
  end

  describe "a cold cache" do
    test "answers nil and starts no check", %{health: health} do
      Application.put_env(:kiln_cms, Health, Keyword.put(health, :enabled, true))

      assert {:ok, nil} = read(user(:admin))
      assert Process.whereis(Health.warmer_name()) == nil
      assert Health.cached() == nil
    end

    test "answers the cached report once a check filled it", %{health: health} do
      Application.put_env(:kiln_cms, Health, Keyword.put(health, :enabled, true))
      Health.put_cache(%{hex: %{}, notices: :disabled})

      assert {:ok, %Report{state: :fresh, plugins: [_ | _]}} = read(user(:admin))
    end
  end
end
