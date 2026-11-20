defmodule KilnCMS.Backups.Destination.RemotePathTest do
  @moduledoc """
  The path rules Kiln's remote destinations share (#2221, #2222): a folder
  setting, the file a call names, and the names a listing answers.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Destination.RemotePath

  test "a folder setting is segments of safe characters, ends trimmed" do
    assert RemotePath.segments("/backups/kiln/", "the path") == {:ok, ["backups", "kiln"]}
    assert RemotePath.segments("", "the path") == {:ok, []}
    assert RemotePath.segments(nil, "the path") == {:ok, []}

    for hostile <- ["../x", "a/../../b", "~/x", "a/./b", "a b", "a\0b", "a//b"] do
      assert {:error, message} = RemotePath.segments(hostile, "the path"), inspect(hostile)
      assert message =~ "the path"
    end

    assert {:error, "the path is too long"} =
             RemotePath.segments(String.duplicate("a/", 300), "the path")

    assert {:error, "the path must be text"} = RemotePath.segments(1, "the path")
  end

  test "a call touches only a backup subdirectory and a single safe name" do
    assert :ok = RemotePath.safe_ref("db", "kiln-db-20260101-000000.dump")

    for {subdir, name} <- [
          {"../db", "x.dump"},
          {"etc", "x.dump"},
          {"db", "../../etc/passwd"},
          {"db", ".."},
          {"db", "a/b"},
          {"db", ""},
          {"db", nil}
        ] do
      assert {:error, _} = RemotePath.safe_ref(subdir, name), inspect({subdir, name})
    end
  end

  test "a listing answers whole backup files only" do
    assert RemotePath.listed_name?("kiln-db-20260101-000000.dump")
    assert RemotePath.listed_name?("kiln-db-20260101-000000.sha256")

    for hostile <- [
          "kiln-db-20260101-000000.dump.partial",
          "../kiln-db-20260101-000000.dump",
          "kiln-db-20260101-000000.dump\0",
          "..",
          "notes.txt",
          nil
        ] do
      refute RemotePath.listed_name?(hostile), inspect(hostile)
    end
  end
end
