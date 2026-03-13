defmodule Forge.TextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Forge.Text

  property "count_leading_spaces/1" do
    check all(
            maybe_spaces <- string([?\t, ?\s]),
            string_base <- string(:printable)
          ) do
      maybe_with_leading_spaces = maybe_spaces <> string_base
      space_count = byte_size(maybe_spaces)
      assert Text.count_leading_spaces(maybe_with_leading_spaces) == space_count
    end
  end
end
