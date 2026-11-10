defmodule KilnCMS.CMS.ReservedPathAuditTest do
  @moduledoc """
  `access-denied` is a reserved first segment (#2143): `GET /access-denied` is
  routed ahead of delivery. New writes are refused by the slug and alias
  validations; records stored before the segment was reserved are listed by
  `mix kiln.reserved_paths` (#2374).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ReservedPathAudit

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "admin-rp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rp-#{System.unique_integer([:positive])}"

  # A row stored before the segment was reserved: raw SQL, so no action (and
  # no validation) is involved.
  defp legacy!(table, id, column, value) do
    KilnCMS.Repo.query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [
      value,
      Ecto.UUID.dump!(id)
    ])
  end

  describe "validations refuse access-denied" do
    test "as a page slug" do
      assert {:error, error} =
               CMS.create_page(%{title: "T", slug: "access-denied"}, actor: admin())

      assert Exception.message(error) =~ "conflicts with the /access-denied section URL"
    end

    test "as a page slug changed on update" do
      actor = admin()
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: actor)

      assert {:error, error} = CMS.update_page(page, %{slug: "access-denied"}, actor: actor)
      assert Exception.message(error) =~ "conflicts with the /access-denied section URL"
    end

    test "as a path alias's first segment" do
      actor = admin()

      for alias_path <- ["/access-denied", "/access-denied/old"] do
        assert {:error, error} =
                 CMS.create_post(%{title: "T", slug: slug(), path_alias: alias_path},
                   actor: actor
                 )

        assert Exception.message(error) =~ "starts with a URL segment the system already owns"
      end
    end

    test "but not as a post slug, which lives under /blog/" do
      assert CMS.create_post!(%{title: "T", slug: "access-denied"}, actor: admin()).slug ==
               "access-denied"
    end
  end

  describe "report/0" do
    test "lists a stored page slug and path alias a reserved URL shadows" do
      actor = admin()
      page = CMS.create_page!(%{title: "Old page", slug: slug()}, actor: actor)
      aliased = CMS.create_post!(%{title: "Aliased", slug: slug()}, actor: actor)
      post = CMS.create_post!(%{title: "Post", slug: "access-denied"}, actor: actor)
      fine = CMS.create_page!(%{title: "Fine", slug: slug()}, actor: actor)

      legacy!("pages", page.id, "slug", "access-denied")
      legacy!("posts", aliased.id, "path_alias", "/access-denied/old")

      by_id = Map.new(ReservedPathAudit.report(), &{&1.id, &1})

      assert %{kind: :slug, type: "page", path: "/access-denied", title: "Old page"} =
               by_id[page.id]

      assert %{kind: :path_alias, type: "post", path: "/access-denied/old"} = by_id[aliased.id]

      # A post's `/blog/access-denied` is not shadowed, nor is a free slug.
      refute Map.has_key?(by_id, post.id)
      refute Map.has_key?(by_id, fine.id)
    end

    test "run_and_report/1 fails while anything is listed, and passes when clean" do
      actor = admin()
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: actor)

      assert :ok = ReservedPathAudit.run_and_report(fn _line -> :ok end)

      legacy!("pages", page.id, "slug", "access-denied")
      {:ok, lines} = Agent.start_link(fn -> [] end)

      assert {:error, message} =
               ReservedPathAudit.run_and_report(&Agent.update(lines, fn acc -> [&1 | acc] end))

      assert message =~ "1 record(s)"
      assert Enum.any?(Agent.get(lines, & &1), &(&1 =~ "/access-denied" and &1 =~ page.id))
    end
  end
end
