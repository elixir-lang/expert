defmodule Forge.NodeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Forge.Node

  describe "sanitize/1" do
    test "sanitized names do not contain problematic characters" do
      check all(name <- string(:utf8, min_length: 1)) do
        sanitized = Node.sanitize(name)

        # Should not contain characters that break node name format
        refute String.contains?(sanitized, [".", "@", ":", "-"]),
               "Expected #{inspect(sanitized)} not to contain problematic characters"
      end
    end

    test "periods are replaced with underscores" do
      assert Node.sanitize("expert-lsp.org") == "expert_lsp_org"
      assert Node.sanitize("foo.bar.baz") == "foo_bar_baz"
    end

    test "dashes are replaced with underscores" do
      assert Node.sanitize("my-project") == "my_project"
      assert Node.sanitize("my-cool-project") == "my_cool_project"
    end

    test "at signs are replaced with underscores" do
      assert Node.sanitize("project@name") == "project_name"
    end

    test "colons are replaced with underscores" do
      assert Node.sanitize("project:name") == "project_name"
    end

    test "spaces are replaced with underscores" do
      assert Node.sanitize("my project") == "my_project"
    end

    test "preserves letters and case" do
      assert Node.sanitize("MyProject") == "MyProject"
      assert Node.sanitize("fooBar") == "fooBar"
    end

    test "preserves numbers" do
      assert Node.sanitize("project123") == "project123"
      assert Node.sanitize("123project") == "123project"
    end

    test "preserves underscores" do
      assert Node.sanitize("my_project") == "my_project"
    end

    test "preserves UTF-8 characters" do
      # Japanese katakana
      assert Node.sanitize("プロジェクト") == "プロジェクト"
      # Chinese
      assert Node.sanitize("项目") == "项目"
      # Latin with diacritics
      assert Node.sanitize("proyecto_código") == "proyecto_código"
    end

    test "handles empty string" do
      assert Node.sanitize("") == ""
    end

    test "handles string with only problematic characters" do
      assert Node.sanitize("...") == "___"
      assert Node.sanitize("@@@") == "___"
      assert Node.sanitize(".-:@") == "____"
    end
  end
end
