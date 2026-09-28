defmodule KilnCMSWeb.AutomationLive.WordingTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias KilnCMS.Automation.Rule
  alias KilnCMSWeb.AutomationLive.Wording

  @names %{
    types: %{"post" => "Post"},
    users: %{"u-1" => "Ada Lovelace"},
    segments: %{"s-1" => "Members"}
  }

  defp say(trigger, type, action, config \\ %{}) do
    Wording.summary(
      %{trigger_event: trigger, content_type: type, action: action, config: config},
      @names
    )
  end

  describe "summary/2 — who and when" do
    test "names the content type by its label, or says any content" do
      assert say(:published, "post", :reindex) ==
               "When Post content is published, rebuild the page."

      assert say(:published, nil, :reindex) == "When any content is published, rebuild the page."
      assert say(:published, "", :reindex) == "When any content is published, rebuild the page."
    end

    test "a task trigger reads as a task, whatever it is scoped to" do
      assert say(:assigned, nil, :reindex) =~ "When a task is assigned,"
      assert say(:overdue, "task", :reindex) =~ "When a task is overdue,"
    end

    test "an unknown type label falls back to the type's own name" do
      assert say(:updated, "recipe", :reindex) =~ "When recipe content is updated,"
    end

    test "works on a stored %Rule{} struct, which has no Access" do
      rule = %Rule{
        trigger_event: :published,
        content_type: nil,
        action: :invalidate_cache,
        config: %{}
      }

      assert Wording.summary(rule) == "When any content is published, clear the cache."
    end
  end

  describe "summary/2 — what it does" do
    test "email names the address" do
      assert say(:published, nil, :send_email, %{"to" => "ed@example.com"}) =~
               ", email ed@example.com."

      assert say(:published, nil, :send_email) =~ ", send an email."
    end

    test "newsletter names the segment, or everyone — never a raw id" do
      assert say(:published, nil, :newsletter, %{"segment_id" => "s-1"}) =~
               ", send the newsletter to Members."

      assert say(:published, nil, :newsletter) =~ "to all subscribers."
      refute say(:published, nil, :newsletter, %{"segment_id" => "gone"}) =~ "gone"
    end

    test "intelligence reactions say where the finding lands" do
      assert say(:in_review, nil, :suggest_tags, %{"to" => "ed@example.com"}) =~
               ", suggest tags, emailed to ed@example.com."

      assert say(:in_review, nil, :flag_duplicates, %{"deliver_as" => "comment"}) =~
               ", flag near-duplicates, left as a comment."

      assert say(:in_review, nil, :suggest_links, %{"deliver_as" => "task", "assignee" => "u-1"}) =~
               ", suggest internal links, as a task for Ada Lovelace."
    end

    test "every reaction produces a sentence" do
      for action <- Rule.action_kinds() do
        sentence = say(:published, nil, action)
        assert sentence =~ ~r/\AWhen any content is published, .+\.\z/
        refute sentence =~ "_", "#{action} leaked an atom: #{sentence}"
      end
    end
  end
end
