defmodule KilnCMS.Accounts.EnumerationLookupsTest do
  @moduledoc """
  The lookups behind the admin screens answer a non-admin as if every account
  were absent (#2255, surface 7 and the admin-only lookups).

  `TeamLive`'s "Add or invite" form tells its admin whether an address was
  added (it has a confirmed account) or invited (#2135), and `AccountsLive`
  searches accounts: both are platform-admin pages, an accepted residual
  because an admin may see every account anyway. What
  keeps that residual an admin's alone is not the page but the resource: the
  same `get_user_by_email`, `list_users` and `get_user` calls, made with any
  other actor or none, find nothing, and say the same thing about a registered
  address as about one that is not. The admin-only password reset refuses a
  non-admin before it looks at who it was asked about.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.EnumerationAssertions

  alias KilnCMS.Accounts

  defp user(role, email) do
    Ash.Seed.seed!(Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  # What a caller sees of a result, reduced to a comparable term: the shape of
  # an error (class and message of each member, with the address scrubbed by
  # the assertion) or the ids that came back.
  defp shape({:ok, %{id: _}}), do: :found
  defp shape({:ok, nil}), do: :nothing
  defp shape({:ok, list}) when is_list(list), do: {:rows, length(list)}

  defp shape({:error, %{errors: errors}}),
    do: {:error, Enum.map(errors, &{&1.__struct__, Exception.message(&1)})}

  setup do
    known = "enum-lookup-#{uniq()}@example.com"
    unknown = "enum-lookup-nobody-#{uniq()}@example.com"

    %{
      known: known,
      unknown: unknown,
      emails: [known, unknown],
      target: user(:editor, known),
      viewer: user(:viewer, "enum-lookup-viewer-#{uniq()}@example.com"),
      editor: user(:editor, "enum-lookup-editor-#{uniq()}@example.com")
    }
  end

  test "get_user_by_email: anyone but an admin finds nothing, known or not", ctx do
    for actor <- [nil, ctx.viewer, ctx.editor] do
      for opts <- [[], [not_found_error?: false]] do
        seen =
          assert_indistinguishable(
            fn -> shape(Accounts.get_user_by_email(ctx.known, [actor: actor] ++ opts)) end,
            fn -> shape(Accounts.get_user_by_email(ctx.unknown, [actor: actor] ++ opts)) end,
            ctx.emails
          )

        refute seen == :found
      end
    end
  end

  test "get_user_by_email: control, an admin does find the registered address", ctx do
    admin = user(:admin, "enum-lookup-admin-#{uniq()}@example.com")

    assert {:ok, %{id: id}} = Accounts.get_user_by_email(ctx.known, actor: admin)
    assert id == ctx.target.id
    assert {:error, _} = Accounts.get_user_by_email(ctx.unknown, actor: admin)
  end

  test "a user reads only themselves: their own address is found, nobody else's", ctx do
    assert {:ok, %{id: id}} = Accounts.get_user_by_email(ctx.editor.email, actor: ctx.editor)
    assert id == ctx.editor.id
  end

  test "list_users filtered by address returns no other account", ctx do
    list = fn actor, filter ->
      shape(Accounts.list_users(actor: actor, query: [filter: filter]))
    end

    for actor <- [nil, ctx.viewer, ctx.editor] do
      for operator <- [:eq, :contains] do
        assert_indistinguishable(
          fn -> list.(actor, email: [{operator, ctx.known}]) end,
          fn -> list.(actor, email: [{operator, ctx.unknown}]) end,
          ctx.emails
        )
      end

      emails = [actor: actor] |> Accounts.list_users!() |> Enum.map(&to_string(&1.email))
      refute ctx.known in emails
    end
  end

  test "get_user by id is the same absence for a registered id and a made-up one", ctx do
    for actor <- [nil, ctx.viewer, ctx.editor] do
      assert_indistinguishable(
        fn -> shape(Accounts.get_user(ctx.target.id, actor: actor)) end,
        fn -> shape(Accounts.get_user(Ecto.UUID.generate(), actor: actor)) end,
        ctx.emails
      )
    end
  end

  test "an admin-only password reset refuses a non-admin before it looks at the account",
       ctx do
    for actor <- [nil, ctx.viewer, ctx.editor] do
      seen =
        assert_indistinguishable(
          fn -> shape(Accounts.send_user_password_reset(ctx.target.id, actor: actor)) end,
          fn -> shape(Accounts.send_user_password_reset(Ecto.UUID.generate(), actor: actor)) end,
          ctx.emails
        )

      assert {:error, [{Ash.Error.Forbidden.Policy, _}]} = seen
    end
  end

  test "add-or-invite refuses a non-admin before it looks the address up", ctx do
    for actor <- [nil, ctx.viewer, ctx.editor] do
      attempt = fn email ->
        shape(
          Accounts.add_or_invite_member(
            %{organization_id: Accounts.default_org_id(), email: email},
            actor: actor
          )
        )
      end

      seen =
        assert_indistinguishable(
          fn -> attempt.(ctx.known) end,
          fn -> attempt.(ctx.unknown) end,
          ctx.emails
        )

      assert {:error, [{Ash.Error.Forbidden.Policy, _}]} = seen
    end
  end
end
