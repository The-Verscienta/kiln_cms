defmodule KilnCMS.MailAssertionsTest do
  @moduledoc """
  The order-independent mail assertion itself (#2602, #2617). It replaces
  ordered `assert_email_sent/1` calls, so it must pass on any delivery order
  and still fail on a missing, extra or mismatched mail.
  """
  use ExUnit.Case, async: true

  import KilnCMS.MailAssertions
  import Swoosh.TestAssertions

  defp deliver(to, subject) do
    send(self(), {:email, Swoosh.Email.new(to: to, subject: subject)})
  end

  defp to?(address), do: &(&1.to == [{"", address}])

  test "mail delivered in the reverse order of the predicates passes, returned in predicate order" do
    deliver("b@example.com", "Second")
    deliver("a@example.com", "First")

    assert [%{subject: "First"}, %{subject: "Second"}] =
             assert_delivered([to?("a@example.com"), to?("b@example.com")])

    refute_email_sent()
  end

  test "an extra mail fails, and the message names every mail's recipient and subject" do
    deliver("a@example.com", "Welcome")
    deliver("stranger@example.com", "Not for you")

    error =
      assert_raise ExUnit.AssertionError, fn -> assert_delivered([to?("a@example.com")]) end

    assert error.message =~ "Expected 1 mail(s) matching the predicates one to one, got 2"
    assert error.message =~ ~s(mail 1: to [{"", "a@example.com"}], subject "Welcome")
    assert error.message =~ ~s(mail 2: to [{"", "stranger@example.com"}], subject "Not for you")
    assert error.message =~ "predicate 1 accepts: mail 1"
  end

  test "a missing mail fails, and names the predicate nothing matched" do
    deliver("a@example.com", "Welcome")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_delivered([to?("a@example.com"), to?("b@example.com")])
      end

    assert error.message =~ "got 1 mail(s)"
    assert error.message =~ "predicate 2 accepts: no mail (unmatched)"
  end

  test "a mail no predicate accepts fails even when the counts agree" do
    deliver("a@example.com", "Welcome")
    deliver("c@example.com", "Wrong person")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_delivered([to?("a@example.com"), to?("b@example.com")])
      end

    assert error.message =~ ~s(subject "Wrong person")
    assert error.message =~ "predicate 2 accepts: no mail (unmatched)"
  end

  test "overlapping predicates are paired one to one where first-fit would fail" do
    # `any` accepts both mails and comes first; first-fit would hand it mail 1
    # and leave `only_first` with nothing.
    deliver("a@example.com", "First")
    deliver("b@example.com", "Second")
    any = fn _mail -> true end

    assert [%{subject: "Second"}, %{subject: "First"}] =
             assert_delivered([any, to?("a@example.com")])
  end

  test "the same predicate twice needs two mails" do
    deliver("a@example.com", "Once")

    assert_raise ExUnit.AssertionError, ~r/got 1 mail/, fn ->
      assert_delivered([to?("a@example.com"), to?("a@example.com")])
    end

    deliver("a@example.com", "Once")
    deliver("a@example.com", "Twice")

    assert [_, _] = assert_delivered([to?("a@example.com"), to?("a@example.com")])
  end

  test "a predicate that asserts inside counts as not accepting the other mail" do
    deliver("b@example.com", "For b")
    deliver("a@example.com", "For a")

    strict_a = fn mail ->
      assert mail.to == [{"", "a@example.com"}]
      assert mail.subject == "For a"
    end

    assert [%{subject: "For a"}, %{subject: "For b"}] =
             assert_delivered([strict_a, to?("b@example.com")])
  end

  test "no predicates and no mail passes; no predicates and a mail fails" do
    assert [] = assert_delivered([])

    deliver("a@example.com", "Unexpected")
    assert_raise ExUnit.AssertionError, ~r/Expected 0 mail/, fn -> assert_delivered([]) end
  end

  test "other messages in the mailbox are left alone" do
    send(self(), :unrelated)
    deliver("a@example.com", "Welcome")

    assert [_] = assert_delivered([to?("a@example.com")])
    assert_received :unrelated
  end
end
