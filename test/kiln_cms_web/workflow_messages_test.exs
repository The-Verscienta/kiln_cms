defmodule KilnCMSWeb.WorkflowMessagesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias KilnCMSWeb.WorkflowMessages

  # The Publish, Approve and Return buttons are rendered for admins alone, so
  # a failure described by the VERB ("publishing requires an admin approval")
  # was false for everyone who could ever see it. These pin that the copy
  # follows the error instead.
  describe "error/2" do
    test "only a Forbidden is described as a role problem" do
      forbidden = Ash.Error.Forbidden.exception(errors: [])

      assert WorkflowMessages.error("publish", forbidden) ==
               "Only an admin can publish. Submit the draft for review instead."

      assert WorkflowMessages.error("return", forbidden) ==
               "Only an admin can return content to draft."
    end

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

      message = WorkflowMessages.error("publish", error)

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

        assert WorkflowMessages.error("publish", error) ==
                 "Someone else changed this item's status first — reload to see where it stands."
      end
    end

    test "anything that is not an error falls back to the generic sentence" do
      assert WorkflowMessages.error("publish", :nope) == "That action isn't allowed right now."
    end
  end

  describe "success/2" do
    test "a submit says who acts next; anything else names the new state" do
      assert WorkflowMessages.success("submit", :in_review) ==
               "Sent for review — an admin will publish when ready."

      assert WorkflowMessages.success("publish", :published) =~ "Updated to"
    end
  end
end
