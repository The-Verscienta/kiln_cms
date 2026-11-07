defmodule KilnCMS.Accounts.BreachedPasswordTest do
  @moduledoc """
  The Have I Been Pwned range client (#2240): what goes on the wire, what a
  response means, and that every failure is a classified error rather than a
  guess.

  `async: false`: the stub is installed in application env
  (`KilnCMS.BreachedPasswordFixtures`).
  """
  use ExUnit.Case, async: false

  # The crash test logs the task's death; the assertion is on the result.
  @moduletag :capture_log

  import KilnCMS.BreachedPasswordFixtures

  alias KilnCMS.Accounts.BreachedPassword

  test "a password in the corpus is a hit with its count" do
    password = password()
    enable!(&ok(&1, breached_body(password, 4242)))

    assert {:ok, {:breached, 4242}} = BreachedPassword.check(password)
  end

  test "a password that is not listed is clean" do
    password = password()
    enable!(&ok(&1, clean_body(password)))

    assert {:ok, :clean} = BreachedPassword.check(password)
  end

  test "a padding line (count 0) for the suffix is not a hit" do
    password = password()
    enable!(&ok(&1, padding_only_body(password)))

    assert {:ok, :clean} = BreachedPassword.check(password)
  end

  test "sends only the 5-character prefix, with padding requested" do
    password = password()
    {prefix, suffix} = BreachedPassword.split_hash(password)
    enable!(&ok(&1, clean_body(password)))

    assert {:ok, :clean} = BreachedPassword.check(password)

    assert_received {:hibp_request, path, headers}
    assert path == "/range/" <> prefix
    assert {"add-padding", "true"} in headers
    refute path =~ suffix
    refute inspect(headers) =~ suffix
    refute inspect(headers) =~ password
  end

  test "the hash is SHA-1 in uppercase hex, and the password is not normalised" do
    assert {"5BAA6", "1E4C9B93F3F0682250B6CF8331B7EE68FD8"} =
             BreachedPassword.split_hash("password")

    refute BreachedPassword.split_hash("password") == BreachedPassword.split_hash(" password")
    refute BreachedPassword.split_hash("password") == BreachedPassword.split_hash("Password")
  end

  test "a 500 is an :http_status error" do
    enable!(&Plug.Conn.send_resp(&1, 500, "boom"))
    assert {:error, :http_status} = BreachedPassword.check(password())
  end

  test "a 404 or a redirect is an :http_status error, never followed" do
    enable!(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.test/")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :http_status} = BreachedPassword.check(password())
    assert_received {:hibp_request, _, _}
    refute_received {:hibp_request, _, _}
  end

  test "a 200 that is not a range listing is :malformed" do
    enable!(&ok(&1, "<html><body>maintenance</body></html>"))
    assert {:error, :malformed} = BreachedPassword.check(password())
  end

  test "an empty 200 is :malformed" do
    enable!(&ok(&1, ""))
    assert {:error, :malformed} = BreachedPassword.check(password())
  end

  test "a body over the byte cap is :malformed" do
    enable!(&ok(&1, String.duplicate("A", 200 * 1024)))
    assert {:error, :malformed} = BreachedPassword.check(password())
  end

  test "a transport timeout is :timeout" do
    enable!(&Req.Test.transport_error(&1, :timeout))
    assert {:error, :timeout} = BreachedPassword.check(password())
  end

  test "a refused connection is :transport" do
    enable!(&Req.Test.transport_error(&1, :econnrefused))
    assert {:error, :transport} = BreachedPassword.check(password())
  end

  test "a slow server hits the overall deadline and is :timeout" do
    password = password()

    enable!(
      fn conn ->
        Process.sleep(500)
        ok(conn, clean_body(password))
      end,
      deadline: 50
    )

    assert {:error, :timeout} = BreachedPassword.check(password)
  end

  test "an address SafeFetch refuses is :blocked" do
    enable!(&ok(&1, ""), host: "http://127.0.0.1")
    assert {:error, :blocked} = BreachedPassword.check(password())
    refute_received {:hibp_request, _, _}
  end

  test "a crash inside the request is :transport, not a crash of the caller" do
    enable!(fn _conn -> raise "stub exploded" end)
    assert {:error, :transport} = BreachedPassword.check(password())
  end

  test "a full task supervisor fails open as :transport, not a crash" do
    enable!(&ok(&1, ""))
    %{specs: _, active: active} = Supervisor.count_children(KilnCMS.TaskSupervisor)

    # Fill the shared supervisor to its `max_children` with parked tasks.
    parked =
      for _ <- 1..(100 - active)//1 do
        {:ok, pid} =
          Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> Process.sleep(:infinity) end)

        pid
      end

    try do
      assert {:error, :transport} = BreachedPassword.check(password())
    after
      Enum.each(parked, &Process.exit(&1, :kill))
    end
  end

  test "lookups are off in the suite unless a test turns them on" do
    refute BreachedPassword.enabled?()
  end
end
