defmodule KilnCMS.Firing.FormatVersionMigrationTest do
  @moduledoc """
  Lazy migration of artifacts fired before a shape change (#615).

  `@format_version` was bumped 1 → 2 when `:json` gained `custom_fields` and
  `:json_ld` gained `contentLocation` (#601), but **nothing read the field and
  nothing re-fired**. So every document published before that deploy kept serving
  the v1 shape indefinitely while everything published after served v2 — and a
  consumer could not tell which, because the field that would say so was never
  consulted. The bump was decorative, which is arguably worse than not bumping,
  because it looks like a migration happened.

  Reading it on the delivery path makes it load-bearing: a stale row is served
  once more and re-fired behind the request, so the next shape change is handled
  by the same branch with no deploy step for anyone to forget.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.{CMS, Firing}
  alias KilnCMS.Firing.{Cache, Delivery, Engine}

  setup do
    Engine.reset_log_throttles()
    on_exit(&Engine.reset_log_throttles/0)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()

    page =
      CMS.create_page!(
        %{
          title: "Fired",
          slug: "fv-#{System.unique_integer([:positive])}",
          blocks: [%{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    published = CMS.publish_page!(page, actor: actor)
    drain_oban()
    published
  end

  # Rewrite a fired row back to the pre-#601 shape — the version stamp AND the
  # body. Stamping the version alone would leave the v2 keys in place, so a test
  # asserting "the re-fire restored them" would pass without the re-fire ever
  # running. `custom_fields` is exactly what #601 added to `:json`.
  defp age_artifact(org, page, surface) do
    {:ok, artifact} = Firing.get_artifact(:page, page.id, surface, authorize?: false, tenant: org)

    aged =
      Ash.Seed.update!(artifact, %{
        format_version: 1,
        body: Map.drop(artifact.body, ["custom_fields", "contentLocation"])
      })

    Cache.evict(org, :page, page.id)
    aged
  end

  defp org, do: KilnCMS.Accounts.default_org_id()

  describe "Engine.stale?/1" do
    test "a row from an older shape is stale" do
      assert Engine.stale?(%{format_version: 1})
      refute Engine.stale?(%{format_version: Engine.format_version()})
    end

    # A row that cannot say what it is must not be re-fired on every single read.
    test "an unknown or missing version is not stale" do
      refute Engine.stale?(%{format_version: nil})
      refute Engine.stale?(%{})
      refute Engine.stale?(nil)
    end

    # Guards against a future bump forgetting this file: the version the engine
    # writes and the version rows are stamped with must agree.
    test "the engine writes the version it reports" do
      page = published_page()

      {:ok, artifact} =
        Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: org())

      assert artifact.format_version == Engine.format_version()
    end
  end

  describe "reading a stale artifact" do
    test "serves the stale body rather than failing", %{} do
      page = published_page()
      artifact = age_artifact(org(), page, :web)

      assert {:ok, body} = Engine.read(org(), :page, page.id, :web)
      assert body == artifact.body
    end

    test "serves the OLD shape until the re-fire lands, then the new one" do
      page = published_page()
      aged = age_artifact(org(), page, :json)

      # The aged body is what a pre-#601 document actually has on disk.
      refute Map.has_key?(aged.body, "custom_fields")

      assert {:ok, first} = Engine.read(org(), :page, page.id, :json)
      refute Map.has_key?(first, "custom_fields")

      drain_oban()
      Cache.evict(org(), :page, page.id)

      assert {:ok, second} = Engine.read(org(), :page, page.id, :json)
      assert Map.has_key?(second, "custom_fields")
    end

    test "enqueues a re-fire" do
      page = published_page()
      age_artifact(org(), page, :web)

      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
      Engine.read(org(), :page, page.id, :web)

      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    test "the delivery path enqueues it too — that is the one the public site uses" do
      page = published_page()
      age_artifact(org(), page, :json)

      assert {:ok, _body} = Delivery.read_artifact(org(), :page, page.id, :json)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    # The whole point: draining the queue leaves the row at the current shape, so
    # the document stops being stale rather than being re-fired on every read.
    test "the re-fire brings the row up to the current shape" do
      page = published_page()
      age_artifact(org(), page, :json)

      Engine.read(org(), :page, page.id, :json)
      drain_oban()

      {:ok, artifact} =
        Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: org())

      assert artifact.format_version == Engine.format_version()
      refute Engine.stale?(artifact)
      # The body, not just the stamp: `age_artifact/3` removed this key, so its
      # presence is proof the re-fire actually re-rendered the surface.
      assert Map.has_key?(artifact.body, "custom_fields")
    end

    test "a document published on this build is not re-fired" do
      page = published_page()

      assert {:ok, _} = Engine.read(org(), :page, page.id, :web)
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    # A cache hit never reaches the row, so the check runs on the miss path only.
    # That is deliberate — the alternative is a version read per delivered
    # request — and it still converges, because the re-fire overwrites the cache.
    test "a cached body is served without re-checking the version" do
      page = published_page()
      age_artifact(org(), page, :web)

      # First read: misses the cache, sees the stale row, enqueues.
      Engine.read(org(), :page, page.id, :web)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
      Oban.drain_queue(queue: :firing)

      # Second read is a cache hit and must not enqueue again.
      Engine.read(org(), :page, page.id, :web)
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end
  end

  describe "migrate_if_stale/4" do
    # The read is the delivery path and is expected to survive a database outage
    # (#341) — an outage that would also make the Oban insert fail. So the
    # enqueue must never be the thing that breaks a read.
    #
    # A PID is not JSON-encodable, so `Oban.insert/1` genuinely fails on it. An
    # earlier version of this test passed a made-up type atom, which encodes
    # fine — it asserted `:ok` on the happy path and left a junk job behind,
    # while the rescue it was named for had no coverage at all.
    test "a failure to enqueue does not propagate" do
      log =
        capture_log(fn ->
          assert :ok = Engine.migrate_if_stale(org(), :page, self(), %{format_version: 1})
        end)

      assert log =~ "Could not enqueue a format-version re-fire"
      refute_enqueued(worker: KilnCMS.Firing.FireWorker)
    end

    test "is a no-op for a current artifact" do
      page = published_page()

      assert :ok =
               Engine.migrate_if_stale(org(), :page, page.id, %{
                 format_version: Engine.format_version()
               })

      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    # Rolling a release back after it fired newer rows. Re-firing would silently
    # DOWNGRADE the served body, so the row is left alone — but a build serving a
    # shape its own serializers would not produce is worth saying out loud.
    test "a row newer than the build is left alone, with a warning" do
      page = published_page()

      log =
        capture_log(fn ->
          assert :ok =
                   Engine.migrate_if_stale(org(), :page, page.id, %{
                     format_version: Engine.format_version() + 1
                   })
        end)

      assert log =~ "newer than this build"
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end
  end

  # #615 made a stale row re-fire on the read path, which converges — unless the
  # document can no longer be fired. Then the row stayed stale and every cache
  # miss enqueued again: roughly one wasted job per cache expiry, forever, with
  # no failed job and nothing marking the row as hopeless.
  #
  # These rows are a real state, not a hypothetical: `DeleteArtifacts` purges on
  # unpublish inside a best-effort `try/rescue`, so a failed purge leaves an
  # artifact for a now-draft document.
  describe "a stale artifact whose document can no longer be fired (#664)" do
    defp orphaned_artifact do
      page = published_page()
      age_artifact(org(), page, :json)

      # Unpublish WITHOUT the housekeeping that normally purges — exactly the
      # state a failed `DeleteArtifacts` leaves behind.
      Ash.Seed.update!(page, %{state: :draft, published_at: nil})
      Cache.evict(org(), :page, page.id)

      page
    end

    test "the worker purges the orphaned row instead of leaving it stale" do
      page = orphaned_artifact()

      Engine.read(org(), :page, page.id, :json)
      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
      drain_oban()

      # Gone, not merely re-stamped: the row should not exist at all, which is
      # what unpublish intended.
      refute match?(
               {:ok, _},
               Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: org())
             )
    end

    test "a second read does not enqueue again — the drip converges" do
      # The issue's acceptance criterion. Before this, read → job → row still
      # stale → read → job → … bounded only by how long the deployment lives.
      page = orphaned_artifact()

      Engine.read(org(), :page, page.id, :json)
      drain_oban()

      # A fresh read after the purge. There is no row to be stale, so the read
      # is a plain miss served by a live render, and nothing is queued.
      Cache.evict(org(), :page, page.id)
      Engine.read(org(), :page, page.id, :json)

      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
    end

    test "the job is cancelled, not recorded as a success" do
      # `:ok` said "fired successfully" about a job that fired nothing, so the
      # only trace of an unfireable document was its absence from the artifact
      # table. A cancellation carries the reason.
      page = orphaned_artifact()

      assert {:cancel, reason} =
               perform_job(KilnCMS.Firing.FireWorker, %{
                 "org_id" => org(),
                 "type" => "page",
                 "id" => page.id
               })

      assert reason =~ "purged its orphaned artifacts"
    end

    test "a type no resource answers to is cancelled, not retried forever" do
      assert {:cancel, reason} =
               perform_job(KilnCMS.Firing.FireWorker, %{
                 "org_id" => org(),
                 "type" => "type_that_no_longer_exists",
                 "id" => Ash.UUID.generate()
               })

      assert reason =~ "no content type answers to"
    end

    test "a published document is still fired — purging is only for settled absence" do
      # The guard on the whole change: `:absent` must mean the document is
      # genuinely not there. If it ever widens back to "the read failed", this
      # test is what fails.
      page = published_page()
      age_artifact(org(), page, :json)

      assert :ok =
               perform_job(KilnCMS.Firing.FireWorker, %{
                 "org_id" => org(),
                 "type" => "page",
                 "id" => page.id
               })

      assert {:ok, artifact} =
               Firing.get_artifact(:page, page.id, :json, authorize?: false, tenant: org())

      assert artifact.format_version == Engine.format_version()
    end
  end
end
