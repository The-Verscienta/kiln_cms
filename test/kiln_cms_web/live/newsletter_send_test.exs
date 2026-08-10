defmodule KilnCMSWeb.NewsletterSendTest do
  @moduledoc """
  The positive half of `NewsletterLive`'s send gate (#1166 follow-up).

  `actorless_handler_authz_test.exs` pins that a socket without the tier is
  refused, and mutation-testing proves those gates are load-bearing for the
  refusal. What no test covered is the other direction: that an admin can still
  send. Every assertion in that file is a refusal, so a gate that refused
  *everyone* — the wrong tier, an inverted condition, `platform_admin?/1` where
  the per-org tier was meant — passes all eight, and there is no other
  LiveView-level test of this handler. `newsletter_test.exs` drives
  `Newsletter.send_as_newsletter/2` directly and never reaches the console.

  That gap matters more here than it would elsewhere. The handler is the one
  place in the console where being wrong is permanent in the other direction
  too: a newsletter that silently stops going out is a feature that looks fine
  and does nothing, and the page would report "queued" for a campaign that was
  never queued only if the refusal were noisy — it is silent (`{:noreply,
  socket}`), so a broken gate is invisible from the UI.

  Its own file rather than an addition to the authz suite, because that suite is
  organised around one claim — actor-less handlers refuse the unauthorized — and
  this is the control that makes the claim mean something.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.Newsletter.NewsletterSend

  @password "password123456"

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "nl-send-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A post the console can actually send: published, and drained so the `:web`
  # artifact exists. `send_as_newsletter/2` mails the frozen artifact rather than
  # the editable tree, so without the drain the send is refused `:not_fired`
  # before authorization is ever consulted — and this test would pass while
  # proving nothing about the gate it is named for.
  defp fired_post(actor) do
    n = System.unique_integer([:positive])

    post =
      %{title: "Dispatch #{n}", slug: "nl-send-#{n}"}
      |> KilnCMS.CMS.create_post!(actor: actor)
      |> KilnCMS.CMS.publish_post!(%{}, actor: actor)

    KilnCMS.DataCase.drain_oban()

    post
  end

  defp socket_for(actor, post) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        actor: actor,
        current_user: actor,
        current_org: KilnCMS.Accounts.default_org(),
        posts: [post],
        sends: [],
        send_params: %{"post_id" => "", "segment_id" => "", "subject" => ""}
      }
    }
  end

  test "an admin's send still reaches the fan-out" do
    admin = user(:admin)
    post = fired_post(admin)

    assert {:noreply, sent} =
             KilnCMSWeb.NewsletterLive.handle_event(
               "send",
               %{"send" => %{"post_id" => post.id, "segment_id" => "", "subject" => ""}},
               socket_for(admin, post)
             )

    assert sent.assigns.flash["info"] =~ "queued"

    # The flash alone would pass against a handler that reported success without
    # writing anything, so assert the two things a send actually is: the ledger
    # row, and the job that fans it out.
    assert [%NewsletterSend{content_id: content_id}] =
             Ash.read!(NewsletterSend,
               authorize?: false,
               tenant: KilnCMS.Accounts.default_org_id()
             )

    assert content_id == post.id

    assert [%Oban.Job{}] =
             Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: KilnCMS.Newsletter.SendWorker)
  end
end
