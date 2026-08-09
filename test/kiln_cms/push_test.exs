defmodule KilnCMS.PushTest do
  @moduledoc """
  The Web Push sender and its subscription store (#628): who gets enqueued,
  what the payload may say, and which push-service answers kill a row rather
  than retrying it forever.
  """
  # async: false — configures the global VAPID keys.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.CMS
  alias KilnCMS.Push
  alias KilnCMS.Push.Vapid
  alias KilnCMS.Push.Worker

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
    {public, private} = Vapid.generate()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.merge(original,
        vapid_public_key: public,
        vapid_private_key: private,
        vapid_subject: "mailto:ops@example.com"
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)
    :ok
  end

  defp user(role \\ :admin) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "push-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp subscribe(user, opts \\ []) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    params = %{
      "endpoint" =>
        Keyword.get(
          opts,
          :endpoint,
          "https://push.example.com/x/#{System.unique_integer([:positive])}"
        ),
      "p256dh" => Base.url_encode64(public, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "label" => Keyword.get(opts, :label, "iOS · Safari")
    }

    {:ok, subscription} = Push.subscribe(params, user, nil)
    subscription
  end

  defp stub(status, body \\ "") do
    Req.Test.stub(KilnCMS.Push, fn conn -> Plug.Conn.send_resp(conn, status, body) end)
  end

  defp run(subscription, payload \\ %{"title" => "t", "body" => "b", "url" => "/editor"}) do
    Worker.perform(%Oban.Job{
      args: %{"subscription_id" => subscription.id, "payload" => payload}
    })
  end

  defp reload(subscription),
    do: Ash.get(PushSubscription, subscription.id, authorize?: false, not_found_error?: false)

  describe "subscribe/3" do
    test "stores the browser's keys against the actor" do
      actor = user()
      subscription = subscribe(actor, label: "Android · Chrome")

      assert subscription.user_id == actor.id
      assert subscription.label == "Android · Chrome"
      assert subscription.last_delivered_at == nil
    end

    test "a browser re-subscribing moves its row rather than adding one" do
      actor = user()
      endpoint = "https://push.example.com/same"

      first = subscribe(actor, endpoint: endpoint, label: "Mac · Chrome")
      second = subscribe(actor, endpoint: endpoint, label: "Mac · Chrome")

      assert first.id == second.id
      assert [_only_one] = Push.list(actor)
    end

    test "the same browser signing in as someone else takes the subscription with it" do
      first_user = user()
      second_user = user()
      endpoint = "https://push.example.com/shared-device"

      subscribe(first_user, endpoint: endpoint)
      subscribe(second_user, endpoint: endpoint)

      # The device now belongs to the second account, and the first must stop
      # receiving anything on it.
      assert Push.list(first_user) == []
      assert [%{user_id: owner}] = Push.list(second_user)
      assert owner == second_user.id
    end

    test "a blank or absent label falls back rather than storing empty" do
      actor = user()
      assert subscribe(actor, label: "   ").label == "Browser"
    end
  end

  describe "policies" do
    test "a user sees only their own devices" do
      mine = user(:editor)
      theirs = user(:editor)
      subscribe(mine)
      subscribe(theirs)

      assert [_one] = Push.list(mine)
      assert [_also_one] = Push.list(theirs)
      refute Push.list(mine) == Push.list(theirs)
    end

    test "a user cannot read another user's subscription" do
      owner = user(:editor)
      stranger = user(:editor)
      subscription = subscribe(owner)

      assert {:error, _forbidden} = Ash.get(PushSubscription, subscription.id, actor: stranger)
    end

    test "a user cannot destroy another user's subscription" do
      owner = user(:editor)
      stranger = user(:editor)
      subscription = subscribe(owner)

      assert {:error, _forbidden} = Ash.destroy(subscription, actor: stranger)
      assert {:ok, %{}} = reload(subscription)
    end

    test "unsubscribe only reaches the actor's own endpoint" do
      owner = user(:editor)
      stranger = user(:editor)
      subscription = subscribe(owner, endpoint: "https://push.example.com/owned")

      Push.unsubscribe("https://push.example.com/owned", stranger)
      assert {:ok, %{}} = reload(subscription)

      Push.unsubscribe("https://push.example.com/owned", owner)
      assert {:ok, nil} = reload(subscription)
    end
  end

  describe "notify/2" do
    test "enqueues one job per subscription of every recipient" do
      first = user()
      second = user()
      subscribe(first)
      subscribe(first, endpoint: "https://push.example.com/second-device")
      subscribe(second)

      Push.notify([first, second], %{"title" => "t"})

      assert 3 = Oban.Job |> KilnCMS.Repo.all() |> Enum.count(&(&1.worker =~ "Push.Worker"))
    end

    test "does nothing when push is not configured" do
      actor = user()
      subscribe(actor)
      Application.put_env(:kiln_cms, KilnCMS.Push, req_options: [])

      assert :ok = Push.notify([actor], %{"title" => "t"})
      assert [] = Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))
    end

    test "does nothing for a recipient with no devices" do
      assert :ok = Push.notify([user()], %{"title" => "t"})
      assert [] = Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))
    end

    test "the job carries the subscription id, never its endpoint or auth" do
      actor = user()
      subscription = subscribe(actor)
      Push.notify([actor], %{"title" => "t"})

      [job] = Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))

      # Oban args land in a database row, the dashboard and every error report.
      # Both of these are bearer secrets.
      assert job.args["subscription_id"] == subscription.id
      encoded = Jason.encode!(job.args)
      refute encoded =~ subscription.endpoint
      refute encoded =~ subscription.auth
    end
  end

  describe "Worker.perform/1" do
    test "a 201 marks the device as reached" do
      actor = user()
      subscription = subscribe(actor)
      stub(201)

      assert :ok = run(subscription)
      assert {:ok, %{last_delivered_at: %DateTime{}}} = reload(subscription)
    end

    test "410 Gone prunes the subscription instead of retrying it" do
      actor = user()
      subscription = subscribe(actor)
      stub(410)

      assert :ok = run(subscription)
      assert {:ok, nil} = reload(subscription)
    end

    test "404 prunes it too" do
      actor = user()
      subscription = subscribe(actor)
      stub(404)

      assert :ok = run(subscription)
      assert {:ok, nil} = reload(subscription)
    end

    test "403 prunes it — the deployment rotated its VAPID pair" do
      actor = user()
      subscription = subscribe(actor)
      stub(403)

      assert :ok = run(subscription)
      assert {:ok, nil} = reload(subscription)
    end

    test "a 500 retries and leaves the subscription alone" do
      actor = user()
      subscription = subscribe(actor)
      stub(503)

      assert {:error, {:push_service_error, 503}} = run(subscription)
      assert {:ok, %{}} = reload(subscription)
    end

    test "429 retries rather than discarding a notification someone is waiting for" do
      actor = user()
      subscription = subscribe(actor)
      stub(429)

      assert {:error, {:rate_limited, 429}} = run(subscription)
      assert {:ok, %{}} = reload(subscription)
    end

    test "a subscription deleted before the job runs is not an error" do
      actor = user()
      subscription = subscribe(actor)
      Ash.destroy!(subscription, authorize?: false)

      assert :ok = run(subscription)
    end

    test "a subscription whose stored keys are the wrong size is pruned, not retried forever" do
      actor = user()
      subscription = subscribe(actor)

      # 12 bytes where 16 are required: the key schedule silently changes and
      # the browser drops every payload. Retrying cannot fix stored bytes.
      # Seeded past the resource, because no action can write a key — see the
      # `touch_delivered` note there.
      Ash.Seed.update!(subscription, %{
        auth: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })

      assert :ok = run(subscription)
      assert {:ok, nil} = reload(subscription)
    end

    test "the request carries the headers a push service requires" do
      actor = user()
      subscription = subscribe(actor)
      test_pid = self()

      Req.Test.stub(KilnCMS.Push, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = run(subscription)
      assert_received {:headers, headers}
      headers = Map.new(headers)

      # `content-encoding: aes128gcm` is deliberately absent here and present on
      # the wire: Req's plug adapter (`Req.Steps.run_plug/1`) consumes and
      # deletes the request's content-encoding, emulating a server that has
      # already decoded the body. Asserting it through a stub is not possible;
      # the real adapter sends it, and a push service rejects the body without
      # it.
      assert headers["urgency"] == "high"
      assert String.starts_with?(headers["authorization"], "vapid t=")
      assert String.to_integer(headers["ttl"]) > 0
      assert headers["content-type"] == "application/octet-stream"
    end

    test "the body is the RFC 8188 record, not the plaintext" do
      actor = user()
      subscription = subscribe(actor)
      test_pid = self()

      Req.Test.stub(KilnCMS.Push, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, body})
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = run(subscription, %{"title" => "Review requested", "url" => "/editor"})
      assert_received {:body, body}

      # A push service is a third party: what leaves this node must be the
      # encrypted record, and none of the plaintext may be recoverable from it.
      refute body =~ "Review requested"
      refute body =~ "/editor"

      assert <<_salt::binary-16, 4096::unsigned-big-32, 65::unsigned-8, 4, _rest::binary>> = body
    end
  end

  describe "the workflow dispatcher" do
    test "a review request reaches a reviewer's device, carrying no draft content" do
      author = user(:editor)
      reviewer = user(:admin)
      subscribe(reviewer)

      page =
        CMS.create_page!(
          %{
            title: "Secret unpublished headline",
            slug: "push-#{System.unique_integer([:positive])}"
          },
          actor: author
        )

      CMS.submit_page_for_review!(page, %{}, actor: author)

      [job] = Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))
      payload = job.args["payload"]

      assert payload["title"] == "Review requested"
      assert payload["url"] == "/editor?status=in_review"

      # The whole constraint: a third party routes this, and a lock screen
      # displays it. The kind is fine — it is site structure the public URLs
      # already publish — the headline is not.
      encoded = Jason.encode!(payload)
      refute encoded =~ "Secret unpublished headline"
      refute encoded =~ page.id
      refute encoded =~ page.slug
    end

    test "a reviewer who muted the email also gets no push" do
      author = user(:editor)
      reviewer = user(:admin)
      subscribe(reviewer)

      Ash.update!(reviewer, %{notify_on_review_request: false},
        action: :update_notification_prefs,
        authorize?: false
      )

      page =
        CMS.create_page!(
          %{title: "Quiet", slug: "push-#{System.unique_integer([:positive])}"},
          actor: author
        )

      CMS.submit_page_for_review!(page, %{}, actor: author)

      assert [] = Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))
    end
  end
end
