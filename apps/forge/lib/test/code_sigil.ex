defmodule Forge.Test.CodeSigil do
  def sigil_q(text, opts \\ []) do
    {first, rest} =
      case String.split(text, "\n") do
        ["", first | rest] -> {first, rest}
        [first | rest] -> {first, rest}
      end

    base_indent = indent(first)
    indent_length = String.length(base_indent)

    [first | rest]
    |> Enum.map_join("\n", &strip_leading_indent(&1, indent_length))
    |> maybe_trim(opts)
  end

  defp maybe_trim(iodata, [?t]) do
    iodata
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp maybe_trim(iodata, _) do
    IO.iodata_to_binary(iodata)
  end

  @indent_re ~r/^\s*/
  defp indent(first_line) do
    case Regex.scan(@indent_re, first_line) do
      [[indent]] -> indent
      _ -> ""
    end
  end

  defp strip_leading_indent(s, 0) do
    s
  end

  defp strip_leading_indent(<<" ", rest::binary>>, count) when count > 0 do
    strip_leading_indent(rest, count - 1)
  end

  defp strip_leading_indent(s, _) do
    s
  end
end
