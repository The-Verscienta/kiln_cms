defmodule KilnCMSWeb.EnumerationNewsletterTest do
  @moduledoc """
  The newsletter sign-up form does not say whether an address is subscribed
  (#2255).

  `POST /newsletter/subscribe` answers "check your inbox" for every address a
  stranger could name: a new one, one awaiting confirmation, one already
  confirmed and one that unsubscribed. Compared whole by
  `KilnCMS.EnumerationAssertions`, not by substring.

  What differs, and only in the owner's inbox: a new or still-pending address is
  mailed the confirmation link, a confirmed or unsubscribed one is not (mailing
  them would undo an opt-out or make the endpoint a mail cannon).
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import Swoosh.TestAssertions

  alias KilnCMS.Newsletter

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp subscribed(status) do
    email = address(Atom.to_string(status))
    sub = Newsletter.subscribe!(%{email: email}, authorize?: false)

    case status do
      :pending -> :ok
      :confirmed -> {:ok, _} = Newsletter.confirm_subscriber(sub, authorize?: false)
      :unsubscribed -> {:ok, _} = Newsletter.unsubscribe_subscriber(sub, authorize?: false)
    end

    email
  end

  defp post_subscribe(email) do
    build_conn()
    |> post(~p"/newsletter/subscribe", %{"email" => email})
  end

  for status <- [:pending, :confirmed, :unsubscribed] do
    test "a #{status} address and a new one get the same page" do
      known = subscribed(unquote(status))
      unknown = address("new")

      seen =
        assert_indistinguishable(
          fn -> post_subscribe(known) end,
          fn -> post_subscribe(unknown) end,
          [known, unknown]
        )

      # Pinned, so "equal" cannot mean "equally an error".
      assert seen.status == 200
      assert seen.body =~ "Check your inbox for a confirmation link"
    end
  end

  test "an address that is not an address is the one distinct answer, and says nothing about anyone" do
    seen = observe(post_subscribe("not-an-address"), [])

    assert seen.body =~ "Check that address"
    seen.body =~ "doesn't look like"

    refute seen == observe(post_subscribe(address("new")), [])
  end

  test "the only difference is the owner's mail: sent to new and pending, never to confirmed or unsubscribed" do
    pending = subscribed(:pending)
    confirmed = subscribed(:confirmed)
    unsubscribed = subscribed(:unsubscribed)
    fresh = address("new")
    KilnCMS.DataCase.drain_oban()
    flush_mail()

    for email <- [pending, confirmed, unsubscribed, fresh], do: post_subscribe(email)
    KilnCMS.DataCase.drain_oban()

    for email <- [pending, fresh] do
      assert_email_sent(fn mail -> mail.to == [{"", email}] end)
    end

    refute_email_sent()
  end

  defp flush_mail do
    receive do
      {:email, _} -> flush_mail()
    after
      0 -> :ok
    end
  end
end
