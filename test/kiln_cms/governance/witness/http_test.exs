defmodule KilnCMS.Governance.Witness.HTTPTest do
  @moduledoc """
  The HTTP transparency-log witness (#733).

  The interesting cases are all about **refusing to be a sink that overwrites**.
  A witness the attacker can rewrite is worse than none: they doctor the
  database, rewrite the published checkpoint to match, and
  `mix kiln.audit.checkpoint --audit` passes over the whole thing. So a `POST`
  that comes back as anything other than a create is an error, not a receipt.

  The second theme is `list/1`, which is the load-bearing callback: it is the
  only thing that can answer "the witness holds a checkpoint the database does
  not", which is exactly what a truncation attack produces. An empty list is the
  answer that attack wants, so a malformed response must never be able to
  produce one by accident.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Governance.Witness
  alias KilnCMS.Governance.Witness.HTTP

  @url "https://log.test/kiln"
  @org "11111111-1111-4111-8111-111111111111"

  setup do
    previous = Application.get_env(:kiln_cms, HTTP, [])
    Application.put_env(:kiln_cms, HTTP, Keyword.put(previous, :url, @url))
    on_exit(fn -> Application.put_env(:kiln_cms, HTTP, previous) end)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "no stub for this test") end)
    %{key: Witness.key(@org, 7)}
  end

  defp stub(fun), do: Req.Test.stub(HTTP, fun)

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  describe "publish/2" do
    test "a 201 is a receipt carrying the log's answer and our own digest", %{key: key} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "#{@url}/#{key}")
        |> json(201, %{"tree_size" => 42, "signed_tree_head" => "sth"})
      end)

      assert {:ok, receipt} = HTTP.publish(key, ~s({"a":1}))

      assert receipt["key"] == key
      assert receipt["status"] == 201
      assert receipt["location"] == "#{@url}/#{key}"
      assert receipt["response"]["tree_size"] == 42
      # Our digest of what we SENT, so an audit can tell "the log returned
      # something unparseable" from "the log returned a receipt for other bytes".
      assert receipt["sha256"] ==
               :sha256 |> :crypto.hash(~s({"a":1})) |> Base.encode16(case: :lower)
    end

    test "the request is a POST to the key, with the conditional-create header", %{key: key} do
      parent = self()

      stub(fn conn ->
        send(
          parent,
          {:seen, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "if-none-match")}
        )

        json(conn, 201, %{})
      end)

      assert {:ok, _receipt} = HTTP.publish(key, "{}")

      assert_receive {:seen, "POST", path, ["*"]}
      assert path == "/kiln/" <> key
    end

    test "a 409 is the sink refusing to replace, not a failure to report", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 409, "") end)

      assert {:error, :already_published} = HTTP.publish(key, "{}")
    end

    test "a 412 means the same thing", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 412, "") end)

      assert {:error, :already_published} = HTTP.publish(key, "{}")
    end

    # The case that matters, and the reason this adapter does not simply accept
    # any 2xx: a service that ignores `If-None-Match` and REPLACES the object
    # answers `200 OK`, which is indistinguishable from a successful append
    # unless you insist on `201`.
    test "a 200 is refused — that is what a silent overwrite looks like", %{key: key} do
      stub(fn conn -> json(conn, 200, %{"ok" => true}) end)

      assert {:error, {:not_created, 200}} = HTTP.publish(key, "{}")
    end

    test "a 204 is refused too", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

      assert {:error, {:not_created, 204}} = HTTP.publish(key, "{}")
    end

    test "a server error is reported as one", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, {:http_error, 503}} = HTTP.publish(key, "{}")
    end

    test "an unconfigured url is an error value, not a raise", %{key: key} do
      Application.put_env(:kiln_cms, HTTP, url: nil)

      assert {:error, :witness_url_not_configured} = HTTP.publish(key, "{}")
    end

    # `Req` RAISES on a schemeless URL, and a raise here defeats the point of
    # returning an error value: the publish worker's blanket rescue swallows it,
    # the row never gets its `witness_error`, and a checkpoint silently stays
    # unpublished. A missing scheme is an ordinary operator typo.
    test "a schemeless url is an error value too, not a raise", %{key: key} do
      for bad <- ["log.example/kiln", "ftp://log.example", "https://", "not a url"] do
        Application.put_env(:kiln_cms, HTTP, url: bad)

        assert {:error, :witness_url_invalid} = HTTP.publish(key, "{}"), bad
        assert {:error, :witness_url_invalid} = HTTP.list(@org), bad
      end
    end
  end

  describe "fetch/1" do
    test "returns the published bytes", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"sequence":7})) end)

      assert {:ok, ~s({"sequence":7})} = HTTP.fetch(key)
    end

    # Byte-for-byte, not merely "decodes to the same thing". Both callers compare
    # bytes — `Checkpoint.confirm/5` pattern-matches the published body against
    # the one it sent — and letting Req decode and re-encode only round-tripped
    # identically by accident, because every map in a checkpoint has under 32
    # keys and Erlang flatmaps iterate in sorted order below that. One field more
    # and every publish would have recorded a mismatch reading as "the sink
    # accepted an overwrite it should have refused".
    test "returns the stored bytes exactly, even for a JSON content type", %{key: key} do
      stored = ~s({"zzz":1,"aaa":2})

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, stored)
      end)

      assert {:ok, ^stored} = HTTP.fetch(key)
    end

    test "a 404 is 'not published', which the audit reports as a gap", %{key: key} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :not_published} = HTTP.fetch(key)
    end
  end

  describe "list/1" do
    test "returns the org's keys" do
      stub(fn conn ->
        json(conn, 200, ["#{@org}/000000000001.json", "#{@org}/000000000002.json"])
      end)

      assert {:ok, keys} = HTTP.list(@org)
      assert keys == ["#{@org}/000000000001.json", "#{@org}/000000000002.json"]
      assert Enum.map(keys, &Witness.sequence_from_key/1) == [1, 2]
    end

    # A shim author should not have to guess which spelling Kiln wanted, so an
    # org-relative listing is normalised to the same shape `Witness.key/2`
    # produces — otherwise every key reads as one the database does not have.
    test "an org-relative listing is normalised" do
      stub(fn conn -> json(conn, 200, ["000000000001.json", "/000000000002.json"]) end)

      assert {:ok, keys} = HTTP.list(@org)
      assert keys == ["#{@org}/000000000001.json", "#{@org}/000000000002.json"]
    end

    # "The log holds nothing for this org" is precisely the answer a truncation
    # attack wants the audit to reach. It must come from the log saying so, never
    # from a response this adapter failed to understand.
    test "a body that is not a list of keys is an error, not an empty list" do
      # `%{"keys" => [...]}` is a RECOGNISED paginated shape, so the malformed
      # cases are an object that is neither, a list of non-strings, and non-JSON.
      stub(fn conn -> json(conn, 200, %{"items" => ["000000000001.json"]}) end)
      assert {:error, {:invalid_listing, :not_a_list}} = HTTP.list(@org)

      stub(fn conn -> json(conn, 200, [1, 2, 3]) end)
      assert {:error, {:invalid_listing, :not_strings}} = HTTP.list(@org)

      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "not json at all") end)
      assert {:error, {:invalid_listing, :not_a_list}} = HTTP.list(@org)
    end

    test "a genuinely empty log is an empty list" do
      stub(fn conn -> json(conn, 200, []) end)

      assert {:ok, []} = HTTP.list(@org)
    end

    # A log that has never been written for this org 404s the collection rather
    # than answering `[]`, and that is not a tampering signal.
    test "a 404 collection is empty, not an error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:ok, []} = HTTP.list(@org)
    end

    # The bug the S3 adapter's own comment warns about: a single request against
    # a paginating log reports the sink as SMALLER than it is, and for this audit
    # "smaller" reads as *no missing rows* — the answer a truncation attack
    # wants. Both spellings a shim author is likely to reach for are followed.
    test "a Link: rel=next header is followed" do
      parent = self()

      stub(fn conn ->
        send(parent, {:page, conn.request_path, conn.query_string})

        if conn.query_string == "page=2" do
          json(conn, 200, ["000000000002.json"])
        else
          conn
          |> Plug.Conn.put_resp_header("link", ~s(<#{@url}/#{@org}/?page=2>; rel="next"))
          |> json(200, ["000000000001.json"])
        end
      end)

      assert {:ok, keys} = HTTP.list(@org)
      assert Enum.map(keys, &Witness.sequence_from_key/1) == [1, 2]
      assert_receive {:page, _path, ""}
      assert_receive {:page, _path, "page=2"}
    end

    test "a {keys, next} body is followed too" do
      stub(fn conn ->
        if conn.query_string == "page=2" do
          json(conn, 200, %{"keys" => ["000000000002.json"]})
        else
          json(conn, 200, %{
            "keys" => ["000000000001.json"],
            "next" => "#{@url}/#{@org}/?page=2"
          })
        end
      end)

      assert {:ok, keys} = HTTP.list(@org)
      assert Enum.map(keys, &Witness.sequence_from_key/1) == [1, 2]
    end

    # A `next` pointing at itself must not spin forever inside a Mix task.
    test "a self-referential next is bounded, and says so" do
      stub(fn conn ->
        json(conn, 200, %{"keys" => ["000000000001.json"], "next" => "#{@url}/#{@org}/?p=1"})
      end)

      assert {:error, :witness_listing_too_long} = HTTP.list(@org)
    end

    # A false "the witness holds a checkpoint the database does not" is not
    # free: it is how a real one stops being believed.
    test "a key belonging to another org is not attributed to this one" do
      other = "22222222-2222-4222-8222-222222222222"

      stub(fn conn ->
        json(conn, 200, ["#{@org}/000000000001.json", "#{other}/000000000002.json"])
      end)

      assert {:ok, keys} = HTTP.list(@org)
      assert keys == ["#{@org}/000000000001.json"]
    end

    test "a server error is not mistaken for an empty log" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 502, "") end)

      assert {:error, {:http_error, 502}} = HTTP.list(@org)
    end
  end

  describe "the bearer token" do
    test "is sent when configured, through the Keys providers", %{key: key} do
      System.put_env("KILN_TEST_WITNESS_TOKEN", "s3cret")
      on_exit(fn -> System.delete_env("KILN_TEST_WITNESS_TOKEN") end)

      Application.put_env(:kiln_cms, HTTP,
        url: @url,
        token: {:env, %{"var" => "KILN_TEST_WITNESS_TOKEN"}},
        req_options: [plug: {Req.Test, HTTP}]
      )

      parent = self()

      stub(fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, 201, %{})
      end)

      assert {:ok, _receipt} = HTTP.publish(key, "{}")
      assert_receive {:auth, ["Bearer s3cret"]}
    end

    test "a plain string is accepted, so trying this out needs no tuple", %{key: key} do
      Application.put_env(:kiln_cms, HTTP,
        url: @url,
        token: "plain",
        req_options: [plug: {Req.Test, HTTP}]
      )

      parent = self()

      stub(fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, 201, %{})
      end)

      assert {:ok, _receipt} = HTTP.publish(key, "{}")
      assert_receive {:auth, ["Bearer plain"]}
    end

    # An unresolvable token must not become the string "nil" in an Authorization
    # header — the log would reject it and the checkpoint would go unpublished
    # for a reason nothing names.
    test "an unresolvable token sends no header at all", %{key: key} do
      Application.put_env(:kiln_cms, HTTP,
        url: @url,
        token: {:env, %{"var" => "KILN_TEST_WITNESS_ABSENT"}},
        req_options: [plug: {Req.Test, HTTP}]
      )

      parent = self()

      stub(fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, 201, %{})
      end)

      assert {:ok, _receipt} = HTTP.publish(key, "{}")
      assert_receive {:auth, []}
    end
  end

  describe "describe/0" do
    test "names the endpoint" do
      assert HTTP.describe() == "http (#{@url})"
    end

    test "says so when unconfigured" do
      Application.put_env(:kiln_cms, HTTP, url: nil)

      assert HTTP.describe() =~ "unconfigured"
    end
  end
end
