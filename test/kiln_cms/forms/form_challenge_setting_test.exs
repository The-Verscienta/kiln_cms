defmodule KilnCMS.Forms.FormChallengeSettingTest do
  @moduledoc """
  A form's human-verification setting (`Form.challenge`, #2249): who may
  switch it, when it may be switched on at all, and that a form write reaches
  every node's delivery cache.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide, and the cache-bust test listens on a
  node-wide PubSub topic.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Cache.ClusterBust
  alias KilnCMS.CMS
  alias KilnCMS.FormFixtures

  defp uniq, do: System.unique_integer([:positive])

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fcs-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # An admin of another site: an admin membership there, so no tier on this
  # one. Not `User.role: :admin`, which is a platform admin on every site.
  defp other_org_admin do
    org = KilnCMS.OrgFixtures.org("fcs")
    admin = user(:viewer)

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: admin.id,
      role: :admin
    })

    admin
  end

  defp reload(form), do: CMS.get_form!(form.id, authorize?: false)

  describe "while a form can ask for a check" do
    setup do
      enable!()
      :ok
    end

    test "an admin switches it on and off" do
      admin = FormFixtures.admin()
      form = FormFixtures.form!(%{}, actor: admin)
      assert form.challenge == :off

      assert CMS.update_form!(form, %{challenge: :always}, actor: admin).challenge == :always
      assert CMS.update_form!(reload(form), %{challenge: :off}, actor: admin).challenge == :off
    end

    test "an admin can create a form with it on" do
      assert FormFixtures.form!(%{challenge: :always}).challenge == :always
    end

    test "nobody else may switch it" do
      form = FormFixtures.form!()

      for actor <- [
            user(:editor),
            user(:viewer),
            nil,
            other_org_admin(),
            KilnCMS.Forms.system()
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.update_form(reload(form), %{challenge: :always}, actor: actor),
               "#{inspect(actor && Map.get(actor, :role, actor))} must be refused"
      end

      assert reload(form).challenge == :off
    end

    test "a value outside :off and :always is refused" do
      form = FormFixtures.form!()

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_form(form, %{challenge: :sometimes}, actor: FormFixtures.admin())
    end
  end

  describe "while no form can ask for a check" do
    test "switching it on is refused, with a reason the admin can act on" do
      form = FormFixtures.form!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_form(form, %{challenge: :always}, actor: FormFixtures.admin())

      assert Exception.message(error) =~ "isn't available on this deployment"
    end

    test "creating a form with it on is refused" do
      assert_raise Ash.Error.Invalid, fn -> FormFixtures.form!(%{challenge: :always}) end
    end

    test "a form switched on earlier still saves its other settings" do
      enable!()
      admin = FormFixtures.admin()
      form = FormFixtures.form!(%{challenge: :always}, actor: admin)

      enable!(forms: false)

      renamed = CMS.update_form!(reload(form), %{name: "Renamed"}, actor: admin)
      assert renamed.name == "Renamed"
      assert renamed.challenge == :always

      # Saving the same value again is not a change either.
      assert CMS.update_form!(renamed, %{challenge: :always}, actor: admin).challenge == :always

      # And it can always be switched off.
      assert CMS.update_form!(renamed, %{challenge: :off}, actor: admin).challenge == :off
    end
  end

  describe "a form write reaches every node's delivery cache" do
    setup do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, ClusterBust.topic())
      :ok
    end

    test "on a form write and a form-field write, scoped to the site's payloads" do
      admin = FormFixtures.admin()
      form = FormFixtures.form!(%{}, actor: admin)
      prefix = "published:payload:#{form.org_id}:"
      flush_busts()

      CMS.update_form!(reload(form), %{name: "Renamed"}, actor: admin)
      assert_receive {:bust_prefix, ^prefix}

      [field] = CMS.form_fields_for!(form.id, authorize?: false)
      CMS.update_form_field!(field, %{label: "Your email"}, actor: admin)
      assert_receive {:bust_prefix, ^prefix}

      # Never the full clear: that would empty every site's delivery cache and
      # the fired-artifact cache.
      refute_receive {:bust_all, _node}, 50
    end

    test "leaves the head generation and other shapes alone" do
      admin = FormFixtures.admin()
      form = FormFixtures.form!(%{}, actor: admin)
      org_id = form.org_id

      KilnCMS.Cache.bump_head_generation(org_id)
      generation = KilnCMS.Cache.head_generation(org_id)
      refute generation == "0"

      record_key = "published:record:#{org_id}:page:en:kept"
      payload_key = "published:payload:#{org_id}:page:en:dropped"
      Cachex.put(KilnCMS.Cache.cache_name(), record_key, :kept)
      Cachex.put(KilnCMS.Cache.cache_name(), payload_key, :dropped)

      CMS.update_form!(reload(form), %{name: "Renamed"}, actor: admin)

      assert KilnCMS.Cache.head_generation(org_id) == generation
      assert {:ok, :kept} = Cachex.get(KilnCMS.Cache.cache_name(), record_key)
      assert {:ok, nil} = Cachex.get(KilnCMS.Cache.cache_name(), payload_key)
    end

    test "a refused write busts nothing" do
      form = FormFixtures.form!()
      flush_busts()

      assert {:error, _} = CMS.update_form(reload(form), %{name: "x"}, actor: user(:editor))
      refute_receive {:bust_prefix, _prefix}, 50
      refute_receive {:bust_all, _node}, 50
    end
  end

  defp flush_busts do
    receive do
      {:bust_all, _node} -> flush_busts()
      {:bust_prefix, _prefix} -> flush_busts()
    after
      0 -> :ok
    end
  end
end
