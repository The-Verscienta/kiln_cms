defmodule KilnCMSWeb.AutomationLive.WordingTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias KilnCMS.Automation.Rule
  alias KilnCMSWeb.AutomationLive.Wording

  @names %{
    types: %{"post" => "Post"},
    users: %{"u-1" => "Ada Lovelace"},
    segments: %{"s-1" => "Members"},
    providers: %{"bluesky" => "Bluesky (Kiln)"}
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
               "When Post content is published, rebuild the page and its search entry."

      assert say(:published, nil, :reindex) ==
               "When any content is published, rebuild the page and its search entry."

      assert say(:published, "", :reindex) ==
               "When any content is published, rebuild the page and its search entry."
    end

    test "a task trigger reads as a task when it can fire" do
      assert say(:assigned, nil, :reindex) =~ "When a task is assigned,"
      assert say(:overdue, "task", :reindex) =~ "When a task is overdue,"
    end

    test "a task trigger scoped to a content type says the type, not a task" do
      # `Rule.matching` compares the type exactly, so this rule never fires;
      # "When a task is assigned" would read as if it did.
      assert say(:assigned, "post", :reindex) =~ "When Post content is assigned,"
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

  describe "default_name/2" do
    test "is the sentence, cut to what the name attribute holds" do
      rule = %{trigger_event: :published, action: :broadcast, config: %{}}
      assert Wording.default_name(rule, @names) == Wording.summary(rule, @names)

      long = %{rule | config: %{"topic" => String.duplicate("t", 2_000)}}
      assert String.length(Wording.default_name(long, @names)) == KilnCMS.Limits.line()
    end
  end

  describe "dead_scope?/2" do
    test "flags scopes a trigger can never fire for" do
      assert Wording.dead_scope?(:assigned, "post")
      assert Wording.dead_scope?(:published, "task")
      refute Wording.dead_scope?(:assigned, nil)
      refute Wording.dead_scope?(:assigned, "")
      refute Wording.dead_scope?(:overdue, "task")
      refute Wording.dead_scope?(:published, "post")
      refute Wording.dead_scope?(:health_overdue, nil)
    end
  end

  describe "default_trigger/0" do
    test "is the event select's first option" do
      [{_group, [{_label, first} | _]} | _] = Wording.trigger_options()
      assert Wording.default_trigger() == first
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
    end

    test "an unresolved segment never reads as all subscribers, nor as its id" do
      # Deleted: the send is refused, so it reaches nobody.
      gone = say(:published, nil, :newsletter, %{"segment_id" => "gone"})
      assert gone =~ ", send the newsletter to a segment that no longer exists."

      # Pickers not loaded yet (the disconnected render): can't tell.
      unloaded =
        Wording.summary(%{
          trigger_event: :published,
          action: :newsletter,
          config: %{"segment_id" => "s-1"}
        })

      assert unloaded =~ ", send the newsletter to one segment."

      for sentence <- [gone, unloaded] do
        refute sentence =~ "all subscribers"
        refute sentence =~ "gone"
      end
    end

    test "a network is named by the picker's label" do
      assert say(:published, nil, :social_post, %{"provider" => "bluesky"}) =~
               ", post to Bluesky (Kiln)."

      assert say(:published, nil, :social_post, %{"provider" => "mastodon"}) =~
               ", post to Mastodon."
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
