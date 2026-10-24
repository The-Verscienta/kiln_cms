defmodule KilnCMS.Firing.RefireTest do
  @moduledoc """
  `KilnCMS.Firing.refire/3` (#2048): an overlay re-fires a record Kiln does not
  know is stale, and the record's artifact is rebuilt, its dependents follow
  through the reference graph, and the edit-time announcements — the
  `<type>.updated` webhook and the CDN purge — go out.
  """
  # async: false — sets the global `KilnCMS.CDN` app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CDN.PurgeWorker
  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, FireWorker}
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()
  defp overlay, do: SystemActor.new(:overlay)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "refire-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp page(attrs) do
    Ash.Seed.seed!(
      CMS.Page,
      Map.merge(%{title: "P", slug: "refire-#{uniq()}", state: :published}, attrs)
    )
  end

  defp heading(text), do: [%{"_type" => "heading", "text" => text}]

  defp html(id) do
    Firing.get_artifact!(:page, id, :web, actor: SystemActor.new(:firing), tenant: org_id()).body[
      "html"
    ]
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.CDN, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.CDN,
      Keyword.put(original, :purge_url, "https://purge.example.test/purge")
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.CDN, original) end)
    :ok
  end

  # The overlay's case: a card built at fire time from another install. Here
  # the stale source is the stored tree changed under the artifact without an
  # action, which is what "Kiln doesn't know" looks like from inside.
  test "re-fires the record, cascades to its dependents, and announces it like an edit" do
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: user(:admin))

    herb = page(%{blocks: heading("Safety: none known")})

    article =
      page(%{blocks: [%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => herb.id}}]})

    {:ok, _} = Engine.fire(herb)
    {:ok, _} = Engine.fire(article)
    assert html(article.id) =~ "Safety: none known"

    Ash.Seed.update!(herb, %{blocks: heading("Safety: avoid in pregnancy")})
    assert html(herb.id) =~ "none known"

    assert Firing.refire!("page", [herb.id], actor: overlay(), tenant: org_id()) == 1

    assert [%{args: %{"refire" => true, "id" => id}}] = all_enqueued(worker: FireWorker)
    assert id == herb.id

    Oban.drain_queue(queue: :firing, with_recursion: true)

    assert html(herb.id) =~ "avoid in pregnancy"
    # The dependent re-fired through the reference graph, inlining the new body.
    assert html(article.id) =~ "avoid in pregnancy"

    assert [delivery] = CMS.list_webhook_deliveries!(authorize?: false, tenant: org_id())
    assert delivery.event == "page.updated"
    assert_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    assert_enqueued(worker: PurgeWorker, args: %{"org_id" => org_id()})
  end

  test "a document that is not published fires and announces nothing" do
    draft = page(%{state: :draft, blocks: heading("Draft")})

    assert Firing.refire!("page", [draft.id], actor: overlay(), tenant: org_id()) == 1
    Oban.drain_queue(queue: :firing, with_recursion: true)

    refute_enqueued(worker: PurgeWorker)
    assert Firing.artifacts_for!(:page, draft.id, authorize?: false, tenant: org_id()) == []
  end

  test "a pending re-fire is not queued twice, and does not collapse into a plain fire" do
    herb = page(%{blocks: heading("Herb")})

    # A publish's own job is pending: the refire still gets one of its own,
    # since only the refire announces `updated`.
    {:ok, _} =
      %{"org_id" => org_id(), "type" => "page", "id" => herb.id}
      |> FireWorker.new()
      |> Oban.insert()

    assert Firing.refire!("page", [herb.id, herb.id], actor: overlay(), tenant: org_id()) == 1
    assert Firing.refire!("page", [herb.id], actor: overlay(), tenant: org_id()) == 0
    assert length(all_enqueued(worker: FireWorker)) == 2
  end

  describe "authorization" do
    test "the :overlay system actor, an editor and an admin may ask" do
      herb = page(%{blocks: heading("Herb")})

      for actor <- [overlay(), user(:editor), user(:admin)] do
        assert {:ok, _} = Firing.refire("page", [herb.id], actor: actor, tenant: org_id())
      end
    end

    test "another subsystem, a viewer and an anonymous caller may not" do
      herb = page(%{blocks: heading("Herb")})

      for actor <- [SystemActor.new(:firing), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Firing.refire("page", [herb.id], actor: actor, tenant: org_id())
      end

      refute_enqueued(worker: FireWorker)
    end
  end

  test "an unknown type and a missing tenant are errors, not silent no-ops" do
    assert {:error, error} =
             Firing.refire("no_such_type", [Ash.UUID.generate()],
               actor: overlay(),
               tenant: org_id()
             )

    assert Exception.message(error) =~ "no_such_type"

    assert {:error, error} = Firing.refire("page", [Ash.UUID.generate()], actor: overlay())
    assert Exception.message(error) =~ "tenant"

    refute_enqueued(worker: FireWorker)
  end
end
