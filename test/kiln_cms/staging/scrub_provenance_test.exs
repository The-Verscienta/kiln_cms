defmodule KilnCMS.Staging.ScrubProvenanceTest do
  @moduledoc """
  The staging scrub re-keys the content-signing key (#2974). The owner's
  decision: a scrubbed clone still signs, with a fresh key of its own, so
  nothing it signs verifies as production's. The scrub removes production's
  key and queues `KilnCMS.Provenance.GenerateKeyWorker`, which generates
  staging's under staging's own `SECRET_KEY_BASE`.
  """
  # async: false — provenance config, the endpoint's secret_key_base and the
  # cached stored key are VM-global (as in provenance_default_test.exs).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Governance.VersionSignature
  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Provenance
  alias KilnCMS.Provenance.GenerateKeyWorker
  alias KilnCMS.Provenance.KeyRegistry
  alias KilnCMS.Provenance.Signer
  alias KilnCMS.Repo
  alias KilnCMS.Staging.Scrub

  setup do
    prev = Application.get_env(:kiln_cms, Provenance)

    # Pointed at a variable that is certainly unset, so only the generated key
    # (the `provenance_settings` row) can sign.
    Application.put_env(:kiln_cms, Provenance,
      enabled: true,
      signing_key: {:env, %{"var" => "KILN_TEST_UNSET_#{System.unique_integer([:positive])}"}}
    )

    Provenance.forget_stored_key()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Provenance, prev)
      Provenance.forget_stored_key()
    end)

    :ok
  end

  defp platform_admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "scrub-prov-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp identity do
    %{
      org_id: KilnCMS.Accounts.default_org_id(),
      resource_type: "page",
      source_id: Ecto.UUID.generate(),
      version_id: Ecto.UUID.generate(),
      version_inserted_at: DateTime.utc_now()
    }
  end

  # A signature checked against a public key directly rather than through this
  # instance's key registry: the question is what production's key, held by a
  # third party, makes of it.
  defp verifies?(payload, signature, public_key),
    do: :public_key.verify(payload, :sha256, Base.decode64!(signature), public_key)

  # The vault seals under the endpoint's secret_key_base; switching it stands
  # in for "the staging application, with its own SECRET_KEY_BASE".
  defp use_secret_key_base(secret) do
    endpoint = Application.fetch_env!(:kiln_cms, KilnCMSWeb.Endpoint)

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, secret)
    )
  end

  defp key_jobs do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == "KilnCMS.Provenance.GenerateKeyWorker",
        select: j.args
    )
  end

  defp run_key_job, do: GenerateKeyWorker.perform(%Oban.Job{args: %{}})

  test "a version signed on the scrubbed clone does not verify against production's key" do
    endpoint = Application.fetch_env!(:kiln_cms, KilnCMSWeb.Endpoint)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMSWeb.Endpoint, endpoint) end)
    production_base = String.duplicate("p", 64)
    staging_base = String.duplicate("s", 64)

    # Production, under its own key base, signs once; that caches its key.
    use_secret_key_base(production_base)
    {:ok, :generated} = Provenance.ensure_key(platform_admin())
    {:ok, production} = KeyRegistry.current()

    prod_identity = identity()
    {prod_signature, prod_key_id} = VersionSignature.sign(prod_identity)
    assert prod_key_id == production.key_id
    assert VersionSignature.verify(prod_identity, prod_signature, prod_key_id) == :valid

    # The scrub runs with production's key base, as `bin/kiln_cms eval` on the
    # production host does: it removes the key and queues staging's own.
    summary = Scrub.run([])
    assert summary.provenance_key_removed == 1
    assert {:error, _not_found} = KilnCMS.Firing.get_provenance_settings(authorize?: false)
    refute Provenance.key_available?()
    assert key_jobs() == [%{}]

    # Staging boots with a key base of its own and runs the queued job.
    use_secret_key_base(staging_base)
    assert :ok = run_key_job()

    {:ok, staging} = KeyRegistry.current()
    refute staging.key_id == production.key_id

    row = KilnCMS.Firing.get_provenance_settings!(authorize?: false)
    assert {:ok, _pem} = KilnCMS.Keys.Vault.decrypt(row.private_key_encrypted, staging_base)

    assert {:error, :decrypt_failed} =
             KilnCMS.Keys.Vault.decrypt(row.private_key_encrypted, production_base)

    # The clone signs versions, as itself.
    staging_identity = identity()
    {staging_signature, staging_key_id} = VersionSignature.sign(staging_identity)
    assert staging_key_id == staging.key_id
    assert VersionSignature.verify(staging_identity, staging_signature, staging_key_id) == :valid

    # `Signer.sign/1` signs versions, anchors and manifests alike: what the
    # clone signs verifies with its own key and never with production's.
    payload = "a payload signed on the clone"
    {:ok, signature} = Signer.sign(payload)
    assert verifies?(payload, signature, staging.public_key)
    refute verifies?(payload, signature, production.public_key)

    # And it no longer holds production's key: what production signed is
    # neither valid nor tampered on the clone, just not its to vouch for.
    assert VersionSignature.verify(prod_identity, prod_signature, prod_key_id) == :unknown
  end

  test "the queued job leaves a key that resolves alone" do
    {:ok, :generated} = Provenance.ensure_key(platform_admin())
    Scrub.run([])

    # Generated since (say, from the overview's button) before the job ran.
    {:ok, :generated} = Provenance.ensure_key(platform_admin())
    {:ok, %{key_id: key_id}} = KeyRegistry.current()

    assert :ok = run_key_job()
    assert {:ok, %{key_id: ^key_id}} = KeyRegistry.current()
  end

  # What `KilnCMS.Staging.scrub!/1` warns about: a key in the environment,
  # which wins over the database and which no scrub can remove.
  test "a mounted key that resolves is reported as mounted" do
    refute KilnCMS.Keys.provenance_key_mounted?()

    path = Path.join(System.tmp_dir!(), "scrub-prov-#{System.unique_integer([:positive])}.pem")
    File.write!(path, KilnCMS.Keys.generate_rsa_pem())
    on_exit(fn -> File.rm(path) end)
    config = Application.get_env(:kiln_cms, Provenance)

    Application.put_env(
      :kiln_cms,
      Provenance,
      Keyword.put(config, :signing_key, {:file, %{"path" => path}})
    )

    assert KilnCMS.Keys.provenance_key_mounted?()

    # A generated key is not a mounted one.
    Application.put_env(:kiln_cms, Provenance, config)
    {:ok, :generated} = Provenance.ensure_key(platform_admin())
    refute KilnCMS.Keys.provenance_key_mounted?()
  end

  test "a clone with no generated key loses nothing and queues nothing" do
    summary = Scrub.run([])

    assert summary.provenance_key_removed == 0
    assert key_jobs() == []
    refute Provenance.key_available?()
  end

  test "a re-scrub of a clone that has its own key removes it again" do
    {:ok, :generated} = Provenance.ensure_key(platform_admin())
    assert Scrub.run([]).provenance_key_removed == 1
    assert :ok = run_key_job()
    assert Provenance.key_available?()

    assert Scrub.run([]).provenance_key_removed == 1
    refute Provenance.key_available?()
  end
end
