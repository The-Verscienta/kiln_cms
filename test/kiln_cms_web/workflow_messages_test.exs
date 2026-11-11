defmodule KilnCMSWeb.WorkflowMessagesTest do
  @moduledoc false
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.EditorialSettings
  alias KilnCMSWeb.WorkflowMessages

  @forbidden Ash.Error.Forbidden.exception(errors: [])

  @publish "Only an admin can publish. Submit the draft for review instead."
  @unpublish "Only an admin can unpublish content on this site."
  @archive "Only an admin can archive content on this site."
  @return "Only an admin can return content to draft."
  @scope "You can't edit this content type."
  @generic "You don't have permission to do that."

  # The Publish, Approve and Return buttons are rendered for admins alone, so
  # a failure described by the VERB ("publishing requires an admin approval")
  # was false for everyone who could ever see it. These pin that the copy
  # follows the error instead.
  describe "error/3" do
    test "a publish gate's own sentence reaches the admin it refused" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :state,
              message: "flagged claims: cures colds"
            )
          ]
        )

      message = WorkflowMessages.error("publish", error, [])

      assert message =~ "flagged claims: cures colds"
      refute message =~ "admin"
    end

    test "a lost race against a colleague's transition says so" do
      for race <- [
            AshStateMachine.Errors.NoMatchingTransition.exception(
              old_state: :published,
              target: :published,
              action: :publish
            ),
            Ash.Error.Changes.StaleRecord.exception(resource: KilnCMS.CMS.Page)
          ] do
        error = Ash.Error.Invalid.exception(errors: [race])

        assert WorkflowMessages.error("publish", error, []) ==
                 "Someone else changed this item's status first — reload to see where it stands."
      end
    end

    test "anything that is not an error falls back to the generic sentence" do
      assert WorkflowMessages.error("publish", :nope, []) ==
               "That action isn't allowed right now."
    end
  end

  # Which refusal sentence (#2473): "Only an admin…" only where it is the
  # reason — an editor on a site where publishing needs an admin. Every actor
  # is an org member with the tier on that membership, so a membership-less
  # account (`:none` off the default org) cannot make a row pass by accident.
  describe "forbidden/2 and error/3 on a Forbidden" do
    setup do
      org = seed_org()
      %{org: org, admin: member(org, :admin)}
    end

    test "an editor, while publishing needs an admin, is told an admin does it", ctx do
      context = context(ctx, member(ctx.org, :editor))

      assert WorkflowMessages.error("publish", @forbidden, context) == @publish
      assert WorkflowMessages.error("unpublish", @forbidden, context) == @unpublish
      assert WorkflowMessages.error("archive", @forbidden, context) == @archive
      assert WorkflowMessages.error("return", @forbidden, context) == @return
      assert WorkflowMessages.refusal("publish", context) == :needs_publisher
    end

    test "transitions the switch does not gate get the plain sentence", ctx do
      context = context(ctx, member(ctx.org, :editor))

      for action <- ~w(unarchive publish_changes submit trash mark_reviewed) do
        assert WorkflowMessages.forbidden(action, context) == @generic, action
      end
    end

    test "an editor where editors may publish is not told an admin publishes", ctx do
      allow_editors!(ctx, true)
      context = context(ctx, member(ctx.org, :editor))

      for action <- ~w(publish unpublish archive) do
        assert WorkflowMessages.forbidden(action, context) == @generic, action
      end
    end

    # `return_to_draft` is admin-only whatever the switch says.
    test "return stays an admin's step for an editor where editors may publish", ctx do
      allow_editors!(ctx, true)
      context = context(ctx, member(ctx.org, :editor))

      assert WorkflowMessages.forbidden("return", context) == @return
      assert WorkflowMessages.refusal("return", context) == :needs_admin
    end

    test "an editor scoped away from the type is told so, whatever the switch", ctx do
      editor = member(ctx.org, :editor, ["page"])
      context = context(ctx, editor, KilnCMS.CMS.Post)

      for action <- ~w(publish unpublish archive submit unarchive publish_changes mark_reviewed) do
        assert WorkflowMessages.forbidden(action, context) == @scope, action
      end

      allow_editors!(ctx, true)
      assert WorkflowMessages.forbidden("publish", context) == @scope
      assert WorkflowMessages.refusal("publish", context) == :out_of_scope
    end

    # Return is `OrgAdmin` alone, and a destroy admin-only for everyone: a
    # wider scope would not help, so the scope is not their reason.
    test "a scoped editor refused Return or the trash is not told about the scope", ctx do
      editor = member(ctx.org, :editor, ["page"])
      context = context(ctx, editor, KilnCMS.CMS.Post)

      assert WorkflowMessages.forbidden("return", context) == @return
      assert WorkflowMessages.refusal("return", context) == :needs_admin

      for action <- ~w(trash delete) do
        assert WorkflowMessages.forbidden(action, context) == @generic, action
      end
    end

    test "a record stands for its resource, and dynamic types share the entry scope", ctx do
      editor = member(ctx.org, :editor, ["page"])

      assert WorkflowMessages.forbidden("publish", context(ctx, editor, %KilnCMS.CMS.Post{})) ==
               @scope

      assert WorkflowMessages.forbidden("publish", context(ctx, editor, KilnCMS.CMS.Entry)) ==
               @scope

      entry_editor = member(ctx.org, :editor, ["entry"])

      assert WorkflowMessages.forbidden("publish", context(ctx, entry_editor, KilnCMS.CMS.Entry)) ==
               @publish
    end

    test "an editor inside their scope is told about the switch", ctx do
      editor = member(ctx.org, :editor, ["page"])

      assert WorkflowMessages.forbidden("publish", context(ctx, editor, KilnCMS.CMS.Page)) ==
               @publish
    end

    # The bulk bar refuses before there is one record; the switch alone decides.
    test "with no record, the scope is not asked", ctx do
      editor = member(ctx.org, :editor, ["page"])
      assert WorkflowMessages.forbidden("publish", context(ctx, editor)) == @publish
    end

    test "an admin refused for another reason is not told an admin does it", ctx do
      context = context(ctx, ctx.admin, KilnCMS.CMS.Post)

      for action <- ~w(publish unpublish archive return trash) do
        assert WorkflowMessages.forbidden(action, context) == @generic, action
      end
    end

    test "a viewer gets the plain sentence, return included", ctx do
      context = context(ctx, member(ctx.org, :viewer), KilnCMS.CMS.Post)

      for action <- ~w(publish unpublish archive return) do
        assert WorkflowMessages.forbidden(action, context) == @generic, action
      end
    end

    test "no actor, or a member of another site, gets the plain sentence", ctx do
      other = seed_org()

      for actor <- [nil, member(other, :editor)] do
        assert WorkflowMessages.forbidden("publish", context(ctx, actor)) == @generic
      end
    end

    # The tier is the effective one, decided now: a live grant counts, an
    # expired one does not.
    test "a temporary tier decides the sentence while it lasts", ctx do
      granted_editor = member(ctx.org, :viewer, [], granted(:editor, 1))
      assert WorkflowMessages.forbidden("publish", context(ctx, granted_editor)) == @publish

      granted_admin = member(ctx.org, :editor, [], granted(:admin, 1))
      assert WorkflowMessages.forbidden("publish", context(ctx, granted_admin)) == @generic

      lapsed = member(ctx.org, :viewer, [], granted(:editor, -1))
      assert WorkflowMessages.forbidden("publish", context(ctx, lapsed)) == @generic
    end

    test "another site's switch does not decide this one's sentence", ctx do
      other = seed_org()
      editor = member(ctx.org, :editor)

      {:ok, _} =
        EditorialSettings.save(%{editors_can_publish: true},
          actor: member(other, :admin),
          tenant: other.id
        )

      assert WorkflowMessages.forbidden("publish", context(ctx, editor)) == @publish
    end
  end

  describe "refusal_message/2" do
    test "says a decided refusal without deciding it again" do
      assert WorkflowMessages.refusal_message(:needs_publisher, "archive") == @archive
      assert WorkflowMessages.refusal_message(:out_of_scope, "publish") == @scope
      assert WorkflowMessages.refusal_message(:needs_admin, "return") == @return
      assert WorkflowMessages.refusal_message(:not_permitted, "publish") == @generic
    end
  end

  describe "success/2" do
    test "a submit says who acts next; anything else names the new state" do
      assert WorkflowMessages.success("submit", :in_review) ==
               "Sent for review — an admin will publish when ready."

      assert WorkflowMessages.success("publish", :published) =~ "Updated to"
    end
  end

  defp context(ctx, actor, resource \\ nil) do
    [actor: actor, org: ctx.org.id] ++ if(resource, do: [resource: resource], else: [])
  end

  defp allow_editors!(ctx, value) do
    {:ok, _} =
      EditorialSettings.save(%{editors_can_publish: value}, actor: ctx.admin, tenant: ctx.org.id)
  end

  defp granted(role, hours),
    do: %{
      granted_role: role,
      granted_role_expires_at: DateTime.add(DateTime.utc_now(), hours, :hour)
    }

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Refusal Site",
      slug: "refusal-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # A global `:viewer` whose tier on `org` comes from the membership alone.
  defp member(org, tier, editable_types \\ [], extra \\ %{}) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "refusal-#{tier}-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(
      Accounts.OrgMembership,
      Map.merge(
        %{
          user_id: user.id,
          organization_id: org.id,
          role: tier,
          editable_types: editable_types
        },
        extra
      )
    )

    user
  end
end
