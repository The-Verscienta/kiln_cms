defmodule KilnCMS.Backups.RedactTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Redact

  test "removes URL userinfo" do
    assert Redact.text("could not connect to postgres://kiln:hunter2pw@db:5432/app") ==
             "could not connect to postgres://***@db:5432/app"
  end

  test "removes key=value credentials" do
    out = Redact.text("host=db password=hunter2pw user=kiln token=abc123 keep_days=14")

    refute out =~ "hunter2pw"
    refute out =~ "abc123"
    assert out =~ "host=db"
    assert out =~ "user=kiln"
    assert out =~ "keep_days=14"
  end

  test "removes the credentials of an rclone connection-string remote" do
    remote =
      ":s3,provider=AWS,access_key_id=AKIAEXAMPLE1234,secret_access_key=wJalrXUtnFEMIk7MDENG:kiln-backups"

    out = Redact.text(remote)

    refute out =~ "AKIAEXAMPLE1234"
    refute out =~ "wJalrXUtnFEMIk7MDENG"
    assert out =~ "provider=AWS"
  end

  test "consumes a quoted value whole" do
    out = Redact.text(~s(:sftp,host=h,pass='a b,c:d':path))
    refute out =~ "a b"
    refute out =~ "c:d"
  end

  test "removes known env secrets literally, even where no pattern matches" do
    secret = "s3cr3t/with spaces&odd"
    out = Redact.text("pg_dump failed: bad #{secret} here", [{"PGPASSWORD", secret}])
    assert out == "pg_dump failed: bad *** here"
  end

  test "skips a secret too short to redact without wrecking ordinary words" do
    assert Redact.text("pg_dump: error", [{"PGPASSWORD", "pg"}]) == "pg_dump: error"
  end

  test "text/3 cuts after redacting, so a secret cannot survive as a fragment" do
    secret = "abcdefghijkl"
    out = Redact.text("xx " <> secret, [{"PGPASSWORD", secret}], 6)
    assert out == "xx ***"
  end

  test "text/3 bounds the work on a huge, keyword-dense input" do
    hostile = String.duplicate("passkeytokensecret", 30_000)

    {micros, out} = :timer.tc(fn -> Redact.text(hostile, [], 100) end)

    assert String.length(out) <= 100
    # Quadratic backtracking over the whole 540 KB would take far longer.
    assert micros < 2_000_000
  end

  test "a non-binary is an empty string" do
    assert Redact.text(nil) == ""
  end
end
