defmodule KilnCMS.MailAssertions do
  @moduledoc """
  Asserts on the mail a drain delivered as a **set**, not a sequence (#2602,
  #2617).

  Swoosh's `assert_email_sent/1` checks the *next* `{:email, _}` message in the
  test's mailbox. Two of them in a row after one `KilnCMS.DataCase.drain_oban/0`
  therefore assert a delivery order, and there is none to assert: every mail
  here is a `KilnCMS.Mail.DeliveryWorker` job on the one `:mail` queue, and
  while Oban's drain fetches with `ORDER BY priority, scheduled_at, id`, the
  fetch goes through `UPDATE … RETURNING`, whose row order Postgres does not
  guarantee. A test written that way passes most of the time and fails with
  `Expected truthy, got false` when the other mail happens to come first.

  `assert_delivered/1` takes every mail already in the mailbox and requires an
  exact one-to-one match with the predicates, in any order:

      KilnCMS.DataCase.drain_oban()

      [reset, sign_in] =
        assert_delivered([
          &(&1.subject =~ "Reset your"),
          &(&1.subject =~ "sign-in link")
        ])

  Forcing FIFO instead (`with_limit: 1` in the drain) was rejected: it pins
  Oban's fetch order, costs a query per job suite-wide, and leaves the tests
  silently order-dependent.

  A few tests still carry a local collect-everything helper that predates this
  module and could move onto it: `security/api_key_trip_test.exs` and
  `security/deliver_alert_test.exs` (`collect/1`),
  `accounts/registration_notifications_test.exs` (`delivered/0`),
  `kiln_cms_web/draft_write_key_rotation_test.exs` (`sent_mail/1`) and
  `kiln_cms_web/enumeration_newsletter_test.exs` (`flush_mail/0`).
  """
  import ExUnit.Assertions

  @doc """
  Receives every `{:email, mail}` already in the test's mailbox and asserts
  that the mails and `predicates` pair up one to one: each predicate accepts a
  distinct mail, and no mail is left over. Returns the mails in predicate order.

  A predicate accepts a mail when it returns a truthy value. One that raises
  `ExUnit.AssertionError` (a predicate that `assert`s inside) is treated as not
  accepting that mail, since it is tried against every mail, not only its own.
  Any other exception propagates.

  It does not wait: call it after the drain that delivered the mail.
  """
  @spec assert_delivered([(Swoosh.Email.t() -> as_boolean(term()))]) :: [Swoosh.Email.t()]
  def assert_delivered(predicates) when is_list(predicates) do
    mails = receive_all([])

    accepts =
      for predicate <- predicates do
        for {mail, index} <- Enum.with_index(mails), accepts?(predicate, mail), do: index
      end

    with true <- length(mails) == length(predicates),
         {:ok, indexes} <- assign(accepts, MapSet.new(0..(length(mails) - 1)//1)) do
      Enum.map(indexes, &Enum.at(mails, &1))
    else
      _ -> flunk(failure_message(mails, accepts))
    end
  end

  defp receive_all(acc) do
    receive do
      {:email, mail} -> receive_all([mail | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp accepts?(predicate, mail) do
    !!predicate.(mail)
  rescue
    ExUnit.AssertionError -> false
  end

  # Backtracking over a predicate × mail table: the lists are a handful long,
  # and first-fit is wrong when two predicates accept the same mail.
  defp assign([], _free), do: {:ok, []}

  defp assign([candidates | rest], free) do
    Enum.find_value(candidates, :error, fn index ->
      with true <- MapSet.member?(free, index),
           {:ok, tail} <- assign(rest, MapSet.delete(free, index)) do
        {:ok, [index | tail]}
      else
        _ -> nil
      end
    end)
  end

  defp failure_message(mails, accepts) do
    mail_lines =
      for {mail, index} <- Enum.with_index(mails, 1) do
        "  mail #{index}: to #{inspect(mail.to)}, subject #{inspect(mail.subject)}"
      end

    predicate_lines =
      for {indexes, number} <- Enum.with_index(accepts, 1) do
        accepted =
          case indexes do
            [] -> "no mail (unmatched)"
            _ -> Enum.map_join(indexes, ", ", &"mail #{&1 + 1}")
          end

        "  predicate #{number} accepts: #{accepted}"
      end

    Enum.join(
      [
        "Expected #{length(accepts)} mail(s) matching the predicates one to one, " <>
          "got #{length(mails)} mail(s):"
        | mail_lines
      ] ++ predicate_lines,
      "\n"
    )
  end
end
