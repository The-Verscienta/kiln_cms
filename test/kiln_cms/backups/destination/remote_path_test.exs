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

  test "S3's rule still refuses what only a file server's folder may hold" do
    for wider <- ["a b", "Backup Share", "a+b", "me@host", "a,b"] do
      assert {:error, _} = RemotePath.segments(wider, "the prefix"), inspect(wider)
    end
  end

  describe "folder_segments/2 (a folder on a file server, #3199)" do
    test "spaces, +, @ and , are allowed inside a folder name" do
      assert RemotePath.folder_segments("/volume1/Backup Share/kiln", "the path") ==
               {:ok, ["volume1", "Backup Share", "kiln"]}

      assert RemotePath.folder_segments("/a+b/me@nas/x,y/A-Z_0.9", "the path") ==
               {:ok, ["a+b", "me@nas", "x,y", "A-Z_0.9"]}

      assert RemotePath.folder_segments("  /backups/kiln/  ", "the path") ==
               {:ok, ["backups", "kiln"]}

      assert RemotePath.folder_segments("", "the path") == {:ok, []}
      assert RemotePath.folder_segments(nil, "the path") == {:ok, []}
    end

    test "names that climb, separators and control characters are refused" do
      for hostile <- [
            "..",
            ".",
            "/a/../b",
            "/a/./b",
            "../x",
            "~",
            "~root",
            "/a/~/b",
            "/home/~kiln",
            "a\\..\\b",
            "a\\b",
            "a\0b",
            "a\nb",
            "a\tb",
            "a\rb",
            "a\x7fb",
            "a//b",
            "/Backup Share//kiln",
            "a:b",
            "a*b",
            "a$b",
            "a;b",
            "a'b",
            "a\"b",
            "café"
          ] do
        assert {:error, message} = RemotePath.folder_segments(hostile, "the path"),
               inspect(hostile)

        assert message =~ "the path"
      end
    end

    test "a folder name may not start or end with a space" do
      for edged <- ["/ lead/kiln", "/trail /kiln", "/a/ b ", "/a/   /b", "/a/b /c"] do
        assert {:error, message} = RemotePath.folder_segments(edged, "the path"),
               inspect(edged)

        assert message =~ "space at the start or end"
      end
    end

    test "the same length limits as S3's rule" do
      assert {:ok, [_]} = RemotePath.folder_segments(String.duplicate("a", 255), "the path")

      assert {:error, _} = RemotePath.folder_segments(String.duplicate("a", 256), "the path")

      assert {:error, "the path is too long"} =
               RemotePath.folder_segments(String.duplicate("a b/", 130), "the path")

      assert {:error, "the path must be text"} = RemotePath.folder_segments(1, "the path")
    end
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
