defmodule KilnCMS.ProvenanceTest do
  @moduledoc "Signed, provenance-verified content (#340)."
  # async: false — provenance config + the signing key live in global
  # Application/env state, set per-test here and restored on exit.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Provenance
  alias KilnCMS.Provenance.Canonical

  setup do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_PROV_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(:kiln_cms, KilnCMS.Provenance,
      enabled: true,
      signer: "Kiln Editorial",
      origin: "https://example.test",
      ai_disclosure: :human,
      signing_key: {:env, %{"var" => var}}
    )

    on_exit(fn ->
      if prev, do: Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)
      System.delete_env(var)
    end)

    %{pem: pem}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "prov-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Register an `ai_disclosure` custom field on :page so a per-document value
  # survives ApplyCustomFields (which drops keys not in the type's registry).
  # A plain :string field, so Provenance.normalize_disclosure/1 is the authority
  # on validity (a :select would reject unknowns at write time instead).
  defp define_disclosure_field do
    KilnCMS.CMS.create_field_definition!(
      %{content_type: :page, name: "ai_disclosure", label: "AI disclosure", field_type: :string},
      authorize?: false
    )
  end

  defp fired_artifact(surface, attrs \\ %{}) do
    actor = admin()
    slug = "prov-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        Map.merge(
          %{
            title: "Signed",
            slug: slug,
            blocks: [%{type: :heading, content: "Trust", data: %{"level" => 1}, order: 0}]
          },
          attrs
        ),
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    drain_oban()
    {:ok, artifact} = Firing.get_artifact(:page, page.id, surface, authorize?: false)
    {page, artifact}
  end

  describe "canonical encoding" do
    test "is deterministic regardless of key insertion order" do
      a = %{"b" => 1, "a" => %{"y" => [1, 2], "x" => true}}
      b = %{"a" => %{"x" => true, "y" => [1, 2]}, "b" => 1}
      assert Canonical.encode(a) == Canonical.encode(b)
      assert Canonical.digest(a) == Canonical.digest(b)
    end

    test "sorts nested object keys" do
      assert Canonical.encode(%{"z" => 1, "a" => 2}) == ~s({"a":2,"z":1})
    end
  end

  describe "manifest_for/2" do
    test "binds the artifact hash, signer, origin and disclosure" do
      {page, artifact} = fired_artifact(:web)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      assert manifest["kiln_provenance"] == "1.0"
      assert manifest["artifact"]["type"] == "page"
      assert manifest["artifact"]["surface"] == "web"
      assert manifest["artifact"]["hash"]["alg"] == "sha-256"
      assert manifest["artifact"]["hash"]["value"] == Canonical.digest(artifact.body)
      assert manifest["claim"]["signer"] == "Kiln Editorial"
      assert manifest["claim"]["origin"] == "https://example.test"
      assert manifest["claim"]["ai_disclosure"] == "human"
      assert manifest["signature"]["alg"] == "rsa-sha256"
      assert manifest["signature"]["key_id"] =~ ~r/^sha256:[0-9a-f]{64}$/
      assert is_binary(manifest["signature"]["value"])
    end

    test "reads a per-document AI disclosure from custom_fields" do
      define_disclosure_field()

      {page, artifact} =
        fired_artifact(:json, %{custom_fields: %{"ai_disclosure" => "ai_generated"}})

      {:ok, manifest} = Provenance.manifest_for(artifact, page)
      assert manifest["claim"]["ai_disclosure"] == "ai_generated"
    end

    test "ignores an invalid custom disclosure, falling back to the default" do
      define_disclosure_field()
      {page, artifact} = fired_artifact(:json, %{custom_fields: %{"ai_disclosure" => "bogus"}})
      {:ok, manifest} = Provenance.manifest_for(artifact, page)
      assert manifest["claim"]["ai_disclosure"] == "human"
    end
  end

  describe "verify/2" do
    test "a genuine manifest verifies against the unaltered artifact" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      assert {:ok, %{"verified" => true, "unaltered" => true, "authentic" => true}} =
               Provenance.verify(manifest, artifact.body)
    end

    test "detects a tampered artifact body (hash mismatch)" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      tampered = Map.put(artifact.body, "title", "Injected")

      assert {:ok, %{"verified" => false, "unaltered" => false, "authentic" => true}} =
               Provenance.verify(manifest, tampered)
    end

    test "detects a tampered claim (signature mismatch)" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      forged = put_in(manifest, ["claim", "signer"], "Someone Else")

      assert {:ok, %{"verified" => false, "authentic" => false}} =
               Provenance.verify(forged, artifact.body)
    end

    test "a signature from a different key does not verify" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      # Rotate to a fresh key; the old signature must no longer verify.
      other = KilnCMS.Keys.generate_rsa_pem()
      var = "KILN_TEST_PROV_ROT_#{System.unique_integer([:positive])}"
      System.put_env(var, other)
      cfg = Application.get_env(:kiln_cms, KilnCMS.Provenance)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Provenance,
        Keyword.put(cfg, :signing_key, {:env, %{"var" => var}})
      )

      assert {:ok, %{"authentic" => false}} = Provenance.verify(manifest, artifact.body)
      System.delete_env(var)
    end
  end
end
