defmodule ElixirLS.LanguageServer.SourceFile.PathTest do
  use ExUnit.Case
  use Patch

  import Forge.Document.Path

  defp patch_os(os_type, fun) do
    test = self()

    spawn(fn ->
      patch(Forge.OS, :type, os_type)

      try do
        rv = fun.()
        send(test, {:return, rv})
      rescue
        e ->
          send(test, {:raise, e, __STACKTRACE__})
      end
    end)

    receive do
      {:return, rv} ->
        rv

      {:raise, %ExUnit.AssertionError{} = e, stack} ->
        new_message = "In O/S #{inspect(os_type)} #{e.message}"
        reraise(%ExUnit.AssertionError{e | message: new_message}, stack)

      {:raise, error, stack} ->
        reraise(error, stack)
    end
  end

  def with_os(:windows, fun) do
    patch_os({:win32, :whatever}, fun)
  end

  def with_os(:linux, fun) do
    patch_os({:unix, :linux}, fun)
  end

  def with_os(:macos, fun) do
    patch_os({:unix, :darwin}, fun)
  end

  describe "from_uri/1" do
    # tests based on cases from https://github.com/microsoft/vscode-uri/blob/master/src/test/uri.test.ts

    test "unix" do
      with_os(:windows, fn ->
        assert from_uri("file:///some/path") == "\\some\\path"
        assert from_uri("file:///some/path/") == "\\some\\path\\"
        assert from_uri("file:///nodes%2B%23.ex") == "\\nodes+#.ex"
      end)

      with_os(:linux, fn ->
        assert from_uri("file:///some/path") == "/some/path"
        assert from_uri("file:///some/path/") == "/some/path/"
        assert from_uri("file:///nodes%2B%23.ex") == "/nodes+#.ex"
      end)
    end

    test "UNC" do
      with_os(:windows, fn ->
        assert from_uri("file://shares/files/c%23/p.cs") == "\\\\shares\\files\\c#\\p.cs"

        assert from_uri("file://monacotools1/certificates/SSL/") ==
                 "\\\\monacotools1\\certificates\\SSL\\"

        assert from_uri("file://monacotools1/") == "\\\\monacotools1\\"
      end)

      with_os(:linux, fn ->
        assert from_uri("file://shares/files/c%23/p.cs") == "//shares/files/c#/p.cs"

        assert from_uri("file://monacotools1/certificates/SSL/") ==
                 "//monacotools1/certificates/SSL/"

        assert from_uri("file://monacotools1/") == "//monacotools1/"
      end)
    end

    test "no `path` in URI" do
      with_os(:windows, fn ->
        assert from_uri("file://%2Fhome%2Fticino%2Fdesktop%2Fcpluscplus%2Ftest.cpp") == "\\"
      end)

      with_os(:linux, fn ->
        assert from_uri("file://%2Fhome%2Fticino%2Fdesktop%2Fcpluscplus%2Ftest.cpp") == "/"
      end)
    end

    test "windows drive letter" do
      with_os(:windows, fn ->
        assert from_uri("file:///c:/test/me") == "c:\\test\\me"
        assert from_uri("file:///c%3A/test/me") == "c:\\test\\me"
        assert from_uri("file:///C:/test/me/") == "c:\\test\\me\\"
        assert from_uri("file:///_:/path") == "\\_:\\path"

        assert from_uri(
                 "file:///c:/Source/Z%C3%BCrich%20or%20Zurich%20(%CB%88zj%CA%8A%C9%99r%C9%AAk,/Code/resources/app/plugins"
               ) == "c:\\Source\\Zürich or Zurich (ˈzjʊərɪk,\\Code\\resources\\app\\plugins"
      end)

      with_os(:linux, fn ->
        assert from_uri("file:///c:/test/me") == "/c:/test/me"
        assert from_uri("file:///c%3A/test/me") == "/c:/test/me"
        assert from_uri("file:///C:/test/me/") == "/C:/test/me/"
        assert from_uri("file:///_:/path") == "/_:/path"

        assert from_uri(
                 "file:///c:/Source/Z%C3%BCrich%20or%20Zurich%20(%CB%88zj%CA%8A%C9%99r%C9%AAk,/Code/resources/app/plugins"
               ) == "/c:/Source/Zürich or Zurich (ˈzjʊərɪk,/Code/resources/app/plugins"
      end)
    end

    test "vscode unsaved file uri" do
      assert from_uri("untitled:Untitled-1") == "untitled:Untitled-1"
    end

    test "unsupported uri schemas" do
      assert_raise ArgumentError, fn ->
        from_uri("https://elixir-lang.org")
      end

      assert_raise ArgumentError, fn ->
        from_uri("unsaved://343C3EE7-D575-486D-9D33-93AFFAF773BD")
      end
    end
  end

  describe "to_uri/1" do
    # tests based on cases from https://github.com/microsoft/vscode-uri/blob/master/src/test/uri.test.ts
    test "unix path" do
      unless Forge.OS.windows?() do
        assert "file:///nodes%2B%23.ex" == to_uri("/nodes+#.ex")
        assert "file:///coding/c%23/project1" == to_uri("/coding/c#/project1")

        assert "file:///Users/jrieken/Code/_samples/18500/M%C3%B6del%20%2B%20Other%20Th%C3%AEng%C3%9F/model.js" ==
                 to_uri("/Users/jrieken/Code/_samples/18500/Mödel + Other Thîngß/model.js")

        assert "file:///foo/%25A0.txt" == to_uri("/foo/%A0.txt")
        assert "file:///foo/%252e.txt" == to_uri("/foo/%2e.txt")
      end
    end

    test "windows path" do
      if Forge.OS.windows?() do
        drive_letter = "/" |> Path.expand() |> String.split(":") |> hd()
        assert "file:///c%3A/win/path" == to_uri("c:/win/path")
        assert "file:///c%3A/win/path" == to_uri("C:/win/path")
        assert "file:///c%3A/win/path" == to_uri("c:/win/path/")
        assert nil == to_uri("c:\win\path")

        # this path may actually expand to other drive letter than C: (on GHA runner it expands to D:)
        assert "file:///#{drive_letter}%3A/win/path" == to_uri("/c:/win/path")

        assert "file:///c%3A/win/path" == to_uri("c:\\win\\path")
        assert "file:///c%3A/win/path" == to_uri("c:\\win/path")

        assert "file:///c%3A/test%20with%20%25/path" ==
                 to_uri("c:\\test with %\\path")

        assert "file:///c%3A/test%20with%20%2525/c%23code" ==
                 to_uri("c:\\test with %25\\c#code")
      end
    end

    test "relative path" do
      cwd = File.cwd!()

      uri = to_uri("a.file")

      assert from_uri(uri) ==
               cwd
               |> Path.join("a.file")
               |> maybe_convert_path_separators()

      uri = to_uri("./foo/bar")

      assert from_uri(uri) ==
               cwd
               |> Path.join("foo/bar")
               |> maybe_convert_path_separators
    end

    test "UNC path" do
      if Forge.OS.windows?() do
        assert "file://sh%C3%A4res/path/c%23/plugin.json" ==
                 to_uri("\\\\shäres\\path\\c#\\plugin.json")

        assert "file://localhost/c%24/GitDevelopment/express" ==
                 to_uri("\\\\localhost\\c$\\GitDevelopment\\express")
      end
    end
  end

  defp maybe_convert_path_separators(path) do
    if Forge.OS.windows?() do
      String.replace(path, "/", "\\")
    else
      String.replace(path, "\\", "/")
    end
  end
end
