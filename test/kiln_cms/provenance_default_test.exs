defmodule KilnCMS.ProvenanceDefaultTest do
  @moduledoc """
  Provenance on by default (#1929): the key `/setup` generates, the fallback to
  it when no key is mounted, signing at fire time, and the coverage number.
  """
  # async: false — provenance config, env vars and the cached stored key are
  # VM-global.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.Bootstrap
  alias KilnCMS.CMS
  alias KilnCMS.Keys
  alias KilnCMS.Provenance
  alias KilnCMS.Provenance.KeyRegistry

  setup do
    prev = Application.get_env(:kiln_cms, Provenance)

    # On, with the compiled default's shape — an env var — pointed at one
    # that is certainly unset, so only the generated key can sign.
    Application.put_env(:kiln_cms, Provenance,
      enabled: true,
      signing_key: {:env, %{"var" => "KILN_TEST_UNSET_#{System.unique_integer([:positive])}"}}
    )

    Provenance.forget_stored_key()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Provenance, prev)
      # The stored key is cached VM-wide and the row it came from is rolled
      # back with this test's sandbox: forget it, or every later test signs.
      Provenance.forget_stored_key()
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "provd-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp publish!(actor) do
    page =
      CMS.create_page!(%{title: "Signed", slug: "provd-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    drain_oban()
    page
  end

  defp stored_manifest(page) do
    {:ok, artifact} =
      KilnCMS.Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: page.org_id)

    artifact.manifest
  end

  describe "with no key" do
    test "nothing signs, and the error still names the variable to set" do
      refute Provenance.key_available?()
      assert {:error, {:env_var_unset, "KILN_TEST_UNSET_" <> _}} = Keys.fetch(:provenance)
    end

    test "artifacts fire unsigned rather than being refused" do
      page = publish!(admin())
      assert stored_manifest(page) == nil
      assert %{total: 1, signed: 0, verifiable: 0, share: +0.0} = Provenance.coverage(page.org_id)
    end
  end

  describe "the generated key" do
    test "/setup generates one for the admin it creates" do
      assert {:ok, admin} =
               Bootstrap.create_first_admin(%{
                 email: "first-#{System.unique_integer([:positive])}@example.com",
                 password: "password123456",
                 password_confirmation: "password123456"
               })

      assert Provenance.key_available?()

      assert {:ok, %{key_id: "sha256:" <> _}} =
               KilnCMS.Firing.get_provenance_settings(actor: admin)
    end

    test "signs when no key is mounted, and every fire stores its manifest" do
      actor = admin()
      assert {:ok, :generated} = Provenance.ensure_key(actor)
      assert {:ok, :exists} = Provenance.ensure_key(actor)

      page = publish!(actor)
      manifest = stored_manifest(page)

      {:ok, %{key_id: key_id}} = KeyRegistry.current()
      assert manifest["signature"]["key_id"] == key_id
      assert %{total: 1, signed: 1, verifiable: 1, share: 1.0} = Provenance.coverage(page.org_id)
    end

    test "is written once: a second generate is refused, never a replacement" do
      actor = admin()
      {:ok, _} = KilnCMS.Firing.generate_provenance_key(actor: actor)
      assert {:error, _} = KilnCMS.Firing.generate_provenance_key(actor: actor)
    end

    test "only a platform admin may generate it" do
      editor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "provd-ed-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.Firing.generate_provenance_key(actor: editor)
    end

    test "a mounted key wins, and the generated one keeps verifying as retired" do
      actor = admin()
      {:ok, _} = Provenance.ensure_key(actor)
      page = publish!(actor)
      signed_with = stored_manifest(page)["signature"]["key_id"]

      pem = Keys.generate_rsa_pem()
      var = "KILN_TEST_PROV_MOUNTED_#{System.unique_integer([:positive])}"
      System.put_env(var, pem)
      on_exit(fn -> System.delete_env(var) end)
      cfg = Application.get_env(:kiln_cms, Provenance)

      Application.put_env(
        :kiln_cms,
        Provenance,
        Keyword.put(cfg, :signing_key, {:env, %{"var" => var}})
      )

      assert {:ok, ^pem} = Keys.fetch(:provenance)
      assert {:ok, %{key_id: current}} = KeyRegistry.current()
      refute current == signed_with
      assert Enum.any?(KeyRegistry.retired(), &(&1.key_id == signed_with))

      {:ok, artifact} =
        KilnCMS.Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: page.org_id)

      assert {:verified, _} = Provenance.verdict(artifact)
    end

    test "a mounted file that cannot be read fails loudly instead of falling back" do
      {:ok, _} = Provenance.ensure_key(admin())
      cfg = Application.get_env(:kiln_cms, Provenance)

      Application.put_env(
        :kiln_cms,
        Provenance,
        Keyword.put(cfg, :signing_key, {:file, %{"path" => "/nonexistent/kiln-provenance.pem"}})
      )

      assert {:error, {:unreadable, _path, _posix}} = Keys.fetch(:provenance)
    end
  end

  test "coverage counts artifacts whose key this instance no longer holds as signed, not verifiable" do
    actor = admin()
    {:ok, _} = Provenance.ensure_key(actor)
    page = publish!(actor)

    KilnCMS.Repo.query!(
      "UPDATE published_artifacts SET manifest = jsonb_set(manifest, '{signature,key_id}', '\"sha256:gone\"') WHERE document_id = $1",
      [Ecto.UUID.dump!(page.id)]
    )

    assert %{total: 1, signed: 1, verifiable: 0} = Provenance.coverage(page.org_id)
  end
end
