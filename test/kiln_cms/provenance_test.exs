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

    test "encodes floats (a body with a decimal must not crash)" do
      # An artifact body can contain a decimal (a numeric custom field, a rating,
      # a JSON-LD coordinate); encoding/digesting it must not raise.
      body = %{"rating" => 4.5, "nested" => %{"price" => 9.99}}
      assert Canonical.encode(body) == ~s({"nested":{"price":9.99},"rating":4.5})
      assert is_binary(Canonical.digest(body))
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

  describe "parse_key_files/1" do
    test "splits a comma-separated list of paths" do
      assert Provenance.parse_key_files("/etc/kiln/2025.pub.pem,/etc/kiln/2024.pub.pem") ==
               ["/etc/kiln/2025.pub.pem", "/etc/kiln/2024.pub.pem"]
    end

    test "trims surrounding whitespace on each path" do
      assert Provenance.parse_key_files(" /etc/kiln/2025.pub.pem , /etc/kiln/2024.pub.pem ") ==
               ["/etc/kiln/2025.pub.pem", "/etc/kiln/2024.pub.pem"]
    end

    test "drops blank entries so a trailing comma is harmless" do
      assert Provenance.parse_key_files("/etc/kiln/2025.pub.pem, ,") == ["/etc/kiln/2025.pub.pem"]
    end

    test "an all-blank value is an empty list, not a bogus entry" do
      # runtime.exs skips the empty string before calling this, but a value of
      # "," or "  ,  " must not register a key whose path is "".
      assert Provenance.parse_key_files("") == []
      assert Provenance.parse_key_files("  ,  ") == []
    end

    test "the result is not a keyword list, so Config cannot deep-merge it" do
      # The reason these are paths and not {:file, %{…}} tuples: a list of those
      # tuples IS a keyword list, so a runtime `config … retired_keys: [...]`
      # would Keyword.merge into a source-configured :retired_keys and delete
      # every :file entry there. Guarding the property, not the implementation.
      refute Keyword.keyword?(Provenance.parse_key_files("/a.pem,/b.pem"))
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

    test "a bad signature under a key we hold is inauthentic" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      # key_id still names the active key, so we CAN check the signature —
      # and it fails. That is a forgery verdict, not an inconclusive one.
      <<first, rest::binary>> = Base.decode64!(manifest["signature"]["value"])
      forged_bytes = Base.encode64(<<Bitwise.bxor(first, 0xFF), rest::binary>>)
      forged = put_in(manifest, ["signature", "value"], forged_bytes)

      assert {:ok, %{"verified" => false, "authentic" => false}} =
               Provenance.verify(forged, artifact.body)
    end

    test "after rotation an unregistered key is inconclusive, not inauthentic" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      rotate!(retired: [])

      # We no longer hold the key this manifest names. Reporting `authentic:
      # false` here would be a false accusation against our own content.
      assert {:error, {:unknown_key_id, key_id}} = Provenance.verify(manifest, artifact.body)
      assert key_id == manifest["signature"]["key_id"]
    end

    test "a manifest signed before a rotation still verifies via the retired registry" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      rotate!(retired: :previous)

      assert {:ok, %{"verified" => true, "authentic" => true, "unaltered" => true}} =
               Provenance.verify(manifest, artifact.body)
    end

    test "a retired key registered by FILE PATH still verifies (#608)" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      # The route KILN_PROVENANCE_RETIRED_KEY_FILES takes: a comma-separated
      # list of paths, parsed into :file provider tuples. Before #608 this
      # shape was reachable only by editing config/config.exs and rebuilding,
      # so an operator who rotated on a released image and destroyed the
      # outgoing private half could never verify pre-rotation signatures again.
      rotate!(retired: :previous_as_file)

      assert {:ok, %{"verified" => true, "authentic" => true, "unaltered" => true}} =
               Provenance.verify(manifest, artifact.body)
    end

    test "an unreadable retired path is skipped, not fatal to the keys that resolve" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      # A stale path in the list (a secret unmounted, a typo) must not blind
      # verification for the key that IS readable — the whole point of
      # KeyRegistry skipping unresolvable entries.
      rotate!(retired: :previous_as_file, extra_paths: ["/nonexistent/kiln-retired.pub.pem"])

      assert {:ok, %{"verified" => true, "authentic" => true}} =
               Provenance.verify(manifest, artifact.body)
    end

    test "retired_key_files unions with retired_keys rather than replacing it" do
      {page, artifact} = fired_artifact(:json)
      {:ok, manifest} = Provenance.manifest_for(artifact, page)

      # A key registered in source and one registered from the environment must
      # both verify. The env route adding keys is fine; it removing one an
      # operator configured in source would be the bug #608 is about.
      unrelated = KilnCMS.Keys.generate_rsa_pem()
      {:ok, unrelated_key} = KilnCMS.Keys.rsa_private_key(unrelated)

      rotate!(retired: :previous_as_file)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Provenance,
        Keyword.put(
          Application.get_env(:kiln_cms, KilnCMS.Provenance),
          :retired_keys,
          [KilnCMS.Keys.rsa_public_key_pem(unrelated_key)]
        )
      )

      assert {:ok, %{"verified" => true}} = Provenance.verify(manifest, artifact.body)

      {:ok, info} = Provenance.Signer.public_key_info()
      assert length(info["keys"]) == 3
    end

    test "public_key_info lists the active key plus every retired one" do
      rotate!(retired: :previous)

      {:ok, info} = Provenance.Signer.public_key_info()
      assert [%{"status" => "active"} = active, %{"status" => "retired"} = retired] = info["keys"]

      # The top-level fields keep describing the active key (existing contract).
      assert info["key_id"] == active["key_id"]
      assert retired["key_id"] != active["key_id"]
      assert retired["public_key_pem"] =~ "PUBLIC KEY"
    end
  end

  # Rotate to a fresh signing key. `retired: :previous` publishes the outgoing
  # key's public half inline; `:previous_as_file` writes it to disk and goes
  # through `parse_key_files/1`, the KILN_PROVENANCE_RETIRED_KEY_FILES route;
  # `retired: []` simulates an operator who rotated without registering
  # anything. `:extra_paths` appends paths to the parsed list.
  defp rotate!(opts) do
    cfg = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    {:env, %{"var" => var}} = Keyword.fetch!(cfg, :signing_key)
    {:ok, outgoing} = KilnCMS.Keys.rsa_private_key(System.get_env(var))

    rotated_var = "KILN_TEST_PROV_ROT_#{System.unique_integer([:positive])}"
    System.put_env(rotated_var, KilnCMS.Keys.generate_rsa_pem())
    on_exit(fn -> System.delete_env(rotated_var) end)

    rotated = [signing_key: {:env, %{"var" => rotated_var}}]

    registration =
      case Keyword.fetch!(opts, :retired) do
        :previous ->
          [retired_keys: [KilnCMS.Keys.rsa_public_key_pem(outgoing)]]

        :previous_as_file ->
          paths = [write_public_pem!(outgoing) | Keyword.get(opts, :extra_paths, [])]
          [retired_key_files: paths |> Enum.join(",") |> Provenance.parse_key_files()]

        list when is_list(list) ->
          [retired_keys: list]
      end

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      cfg
      |> Keyword.merge(retired_keys: [], retired_key_files: [])
      |> Keyword.merge(rotated ++ registration)
    )
  end

  defp write_public_pem!(private_key) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kiln-test-retired-#{System.unique_integer([:positive])}.pub.pem"
      )

    File.write!(path, KilnCMS.Keys.rsa_public_key_pem(private_key))
    on_exit(fn -> File.rm(path) end)

    path
  end
end
