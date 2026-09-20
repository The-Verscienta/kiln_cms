defmodule KilnCMS.CMS.PreviewTokenTest do
  @moduledoc """
  `PreviewToken.mint/3` — who may issue a draft preview link. The gate is the
  editorial read grant (`Checks.ReadableContentType`), not "can read the row":
  a published document is readable by anyone, but its preview carries the
  pending working copy only editors see.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken

  defp user(role, extra \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "ptok-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  defp slug, do: "ptok-#{System.unique_integer([:positive])}"

  defp draft_page(actor), do: CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

  defp live_page(actor) do
    page = actor |> draft_page() |> CMS.publish_page!(%{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)
  end

  defp mint(type, id, actor, org \\ nil),
    do:
      PreviewToken.mint(type, id, actor: actor, tenant: org || KilnCMS.Accounts.default_org_id())

  describe "mint/3" do
    test "an editor mints a token that names the document, its type and its site" do
      editor = user(:editor)
      page = draft_page(editor)

      assert {:ok, minted} = mint("page", page.id, editor)

      assert %{type: "page", id: id, url: url, expires_at: %DateTime{} = expires_at} = minted
      assert id == page.id
      assert url == KilnCMSWeb.Tenant.base_url(page.org_id) <> "/preview/" <> minted.token

      remaining = DateTime.diff(expires_at, DateTime.utc_now())
      assert remaining > PreviewToken.max_age_seconds() - 5
      assert remaining <= PreviewToken.max_age_seconds()

      assert {:ok, %{type: "page", id: ^id, org_id: org_id}} = PreviewToken.verify(minted.token)
      assert org_id == page.org_id
    end

    test "an admin mints, and the type may be given as an atom" do
      admin = user(:admin)
      page = draft_page(admin)

      assert {:ok, %{type: "page"}} = mint(:page, page.id, admin)
    end

    test "nobody mints without an actor — not even for published content" do
      page = live_page(user(:admin))

      assert {:error, :not_found} = mint("page", page.id, nil)
    end

    test "a viewer is refused: :forbidden on what they can read, :not_found on a draft" do
      admin = user(:admin)
      viewer = user(:viewer)

      # The live row is theirs to read, the working copy is not.
      assert {:error, :forbidden} = mint("page", live_page(admin).id, viewer)
      # The draft is invisible to them, so its existence is not confirmed.
      assert {:error, :not_found} = mint("page", draft_page(admin).id, viewer)
    end

    test "an editor whose read scope leaves this type out is refused on a live document" do
      admin = user(:admin)
      scoped = user(:editor, %{editable_types: ["post"], readable_types: ["post"]})

      assert {:error, :forbidden} = mint("page", live_page(admin).id, scoped)
      assert {:error, :not_found} = mint("page", draft_page(admin).id, scoped)
    end

    test "an unknown type, a missing record and a malformed id are all :not_found" do
      admin = user(:admin)
      page = draft_page(admin)

      assert {:error, :not_found} = mint("no_such_type", page.id, admin)
      assert {:error, :not_found} = mint("page", Ecto.UUID.generate(), admin)
      assert {:error, :not_found} = mint("page", "not-a-uuid", admin)
    end

    test "the read is scoped to the site the request is for" do
      admin = user(:admin)
      page = draft_page(admin)
      other = KilnCMS.OrgFixtures.org("ptok")

      assert {:error, :not_found} = mint("page", page.id, admin, other)
    end

    test "an admin-defined type names itself, not the shared entry tier" do
      admin = user(:admin)

      definition =
        CMS.create_type_definition!(
          %{name: "ptok#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      entry = ContentTypes.create!(definition.name, %{title: "Soup", slug: slug()}, actor: admin)

      assert {:ok, %{type: type, token: token}} = mint(definition.name, entry.id, admin)
      assert type == definition.name
      assert {:ok, %{type: ^type}} = PreviewToken.verify(token)
    end
  end

  describe "mintable?/2" do
    test "matches mint/3's gate" do
      admin = user(:admin)
      page = live_page(admin)

      assert PreviewToken.mintable?(page, user(:editor))
      assert PreviewToken.mintable?(page, admin)
      refute PreviewToken.mintable?(page, user(:viewer))
      refute PreviewToken.mintable?(page, user(:editor, %{readable_types: ["post"]}))
      refute PreviewToken.mintable?(page, nil)
    end
  end

  describe "verify/1" do
    test "refuses a token whose type is an atom — the shape before types named themselves" do
      page = draft_page(user(:admin))

      legacy =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, "content preview", %{
          type: :page,
          id: page.id,
          org_id: page.org_id
        })

      assert {:error, :invalid} = PreviewToken.verify(legacy)
    end
  end
end
