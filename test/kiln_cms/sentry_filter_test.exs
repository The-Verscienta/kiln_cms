defmodule KilnCMS.SentryFilterTest do
  @moduledoc """
  The `before_send` hook drops expected transient mail-retry noise and leaves
  every other event untouched.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Mail.TransientDeliveryError
  alias KilnCMS.SentryFilter

  # Sentry.Event enforces :event_id/:timestamp; the values are irrelevant here.
  defp event(fields),
    do: struct!(Sentry.Event, Keyword.merge([event_id: "id", timestamp: "now"], fields))

  test "drops transient mail-delivery failures" do
    event =
      event(
        original_exception: %TransientDeliveryError{message: "transient delivery failure: ..."}
      )

    assert SentryFilter.before_send(event) == nil
  end

  test "passes every other event through unchanged" do
    runtime = event(original_exception: %RuntimeError{message: "boom"})
    assert SentryFilter.before_send(runtime) == runtime

    no_exception = event(original_exception: nil)
    assert SentryFilter.before_send(no_exception) == no_exception
  end

  test "masks a preview token or unlock grant in the request's raw query string (#1887)" do
    request = %Sentry.Interfaces.Request{
      query_string: "preview_token=SFMyNTY.secret&surface=json"
    }

    event = event(original_exception: %RuntimeError{message: "boom"}, request: request)

    assert %Sentry.Event{request: %{query_string: query}} = SentryFilter.before_send(event)
    refute query =~ "SFMyNTY"
    assert URI.decode_query(query)["surface"] == "json"
  end

  describe "malformed LiveView joins (#700)" do
    # The *real* exception, raised by the dependency, rather than a struct built
    # to match the filter. That is the whole value of this test: the filter names
    # a module and a function inside `phoenix_live_view`, and if a version bump
    # renames or reshapes either, a hand-built struct would keep passing while
    # the flood quietly resumed.
    defp join_crash(url) do
      Phoenix.LiveView.Route.live_link_info_without_checks(
        KilnCMSWeb.Endpoint,
        KilnCMSWeb.Router,
        url
      )
    rescue
      error -> error
    end

    test "drops the crash a non-binary url produces" do
      # `%{"url" => nil}` and `%{"url" => 42}` are the payloads from the issue's
      # probe; both reach this call, which accepts only a binary or a `%URI{}`.
      for bad <- [nil, 42, %{}] do
        crash = join_crash(bad)

        assert %FunctionClauseError{} = crash
        assert SentryFilter.before_send(event(original_exception: crash)) == nil
      end
    end

    test "a well-formed url does not crash at all, so nothing is being masked" do
      # Asserted positively. `join_crash/1` rescues *any* exception and returns
      # it, so `refute match?(%FunctionClauseError{}, ...)` would pass just as
      # happily if the well-formed path were crashing with an ArgumentError —
      # the one test meant to prove nothing is masked, proving nothing.
      assert {:internal, %Phoenix.LiveView.Route{}} = join_crash("/sign-in")
    end

    test "keeps a FunctionClauseError from anywhere else" do
      # The narrowness is the point: dropping every `FunctionClauseError`, or
      # everything from `Phoenix.LiveView.Channel`, would swallow real LiveView
      # bugs — which is the opposite of what this exists to protect.
      # A genuine `FunctionClauseError` from unrelated code — raised inside
      # `Calendar.ISO` by way of `Date.new/4` — rather than a constructed
      # struct, so it carries the same shape a real one would.
      elsewhere =
        try do
          Date.new(:not_a_year, 1, 1)
        rescue
          error -> error
        end

      passed = event(original_exception: elsewhere)

      assert %FunctionClauseError{} = elsewhere
      assert SentryFilter.before_send(passed) == passed
    end
  end

  describe "mail bodies (#1843)" do
    test "drops a mail job's message from the Oban integration's extra args" do
      args = %{
        "to" => ["", "reader@example.com"],
        "sealed" => "c2VhbGVk",
        "html_body" => ~s(<a href="https://cms.example/password-reset/LEAKED">x</a>),
        "text_body" => "https://cms.example/password-reset/LEAKED"
      }

      event = event(extra: %{args: args, attempt: 1, queue: "mail"})
      scrubbed = SentryFilter.before_send(event)

      assert scrubbed.extra.args == %{"to" => ["", "reader@example.com"]}
      assert scrubbed.extra.attempt == 1
      refute inspect(scrubbed) =~ "LEAKED"
    end

    test "withholds a message or exception value that quotes a rendered email" do
      dump = ~s({:push, %Swoosh.Email{html_body: "/password-reset/LEAKED"}})

      message =
        event(
          message: %Sentry.Interfaces.Message{
            formatted: "Oban job exited: " <> dump,
            message: "Oban job exited: %s",
            params: [dump]
          }
        )

      exception =
        event(exception: [%Sentry.Interfaces.Exception{type: "Oban.CrashError", value: dump}])

      refute inspect(SentryFilter.before_send(message)) =~ "LEAKED"
      refute inspect(SentryFilter.before_send(exception)) =~ "LEAKED"
    end
  end

  describe "private job args (#2992)" do
    # `extra` exactly as Sentry's Oban integration builds it:
    # `Map.take(job, [:args, :attempt, :id, :max_attempts, :meta, :queue, :tags, :worker])`.
    defp job_extra(worker, args) do
      %Oban.Job{
        id: 7,
        args: args,
        attempt: 1,
        max_attempts: 5,
        meta: %{},
        queue: "default",
        tags: [],
        worker: worker
      }
      |> Map.take([:args, :attempt, :id, :max_attempts, :meta, :queue, :tags, :worker])
    end

    defp frames(vars) do
      %Sentry.Interfaces.Stacktrace{
        frames: [
          %Sentry.Interfaces.Stacktrace.Frame{
            module: "KilnCMS.Automation.RuleWorker",
            function: "run/3",
            vars: vars
          }
        ]
      }
    end

    test "a registered worker's private keys leave extra.args; the ids stay" do
      for {worker, args} <- [
            {"KilnCMS.Automation.RuleWorker",
             %{"rule_id" => "r1", "payload" => %{"title" => "LEAKED"}, "sealed" => "LEAKED"}},
            {"KilnCMS.Forms.AutoresponderWorker",
             %{"form_id" => "f1", "to" => "LEAKED@example.com", "data" => %{"m" => "LEAKED"}}}
          ] do
        scrubbed = SentryFilter.before_send(event(extra: job_extra(worker, args)))

        refute inspect(scrubbed) =~ "LEAKED"
        assert scrubbed.extra.worker == worker
        assert map_size(scrubbed.extra.args) == 1
      end
    end

    test "an unregistered worker's args keep their keys" do
      args = %{"data" => "kept", "payload" => "kept"}
      scrubbed = SentryFilter.before_send(event(extra: job_extra("KilnCMS.Other.Worker", args)))

      assert scrubbed.extra.args == args
    end

    test "a registered worker's stack frames lose their variables" do
      vars = %{"arg0" => ~s(%{"payload" => %{"title" => "LEAKED"}})}

      exception = %Sentry.Interfaces.Exception{
        type: "FunctionClauseError",
        value: "no function clause matching",
        stacktrace: frames(vars)
      }

      thread = %Sentry.Interfaces.Thread{id: 1, stacktrace: frames(vars)}

      scrubbed =
        SentryFilter.before_send(
          event(
            extra: job_extra("KilnCMS.Automation.RuleWorker", %{"rule_id" => "r1"}),
            exception: [exception],
            threads: [thread]
          )
        )

      refute inspect(scrubbed) =~ "LEAKED"
      assert [%{stacktrace: %{frames: [%{vars: nil, function: "run/3"}]}}] = scrubbed.exception
      assert [%{stacktrace: %{frames: [%{vars: nil}]}}] = scrubbed.threads

      # Any other worker's frames are left as Sentry built them.
      other =
        SentryFilter.before_send(
          event(extra: job_extra("KilnCMS.Other.Worker", %{}), exception: [exception])
        )

      assert [%{stacktrace: %{frames: [%{vars: ^vars}]}}] = other.exception
    end
  end

  describe "URLs and process dumps" do
    @secret "T0kenSecretValue123"

    test "the request URL and a Referer header are redacted" do
      request = %Sentry.Interfaces.Request{
        url: "https://example.com/password-reset/#{@secret}?unlock=#{@secret}",
        headers: %{
          "referer" => "https://example.com/preview/#{@secret}",
          "accept" => "text/html"
        }
      }

      event = event(original_exception: %RuntimeError{message: "boom"}, request: request)
      %Sentry.Event{request: scrubbed} = SentryFilter.before_send(event)

      refute inspect(scrubbed) =~ @secret
      assert scrubbed.url == "https://example.com/password-reset/[FILTERED]?unlock=[FILTERED]"
      assert scrubbed.headers["referer"] == "https://example.com/preview/[FILTERED]"
      assert scrubbed.headers["accept"] == "text/html"
    end

    test "a crashed LiveView's state and last message lose the join URL and token assigns" do
      state =
        inspect(%{
          socket: %{
            host_uri: %URI{scheme: "https", host: "example.com", path: "/auth/invite/#{@secret}"},
            assigns: %{token: @secret, page_title: "Invitation"}
          }
        })

      last_message =
        ~s(%Phoenix.Socket.Message{event: "phx_join", payload: %{"url" => "https://example.com/magic_link/#{@secret}"}})

      event =
        event(
          original_exception: nil,
          # Sentry's logger handler passes these on as chardata.
          extra: %{genserver_state: [state], last_message: last_message, other: "kept"}
        )

      %Sentry.Event{extra: extra} = SentryFilter.before_send(event)

      refute inspect(extra) =~ @secret
      assert extra.genserver_state =~ ~s(page_title: "Invitation")
      assert extra.last_message =~ "/magic_link/[FILTERED]"
      assert extra.other == "kept"
    end
  end
end
