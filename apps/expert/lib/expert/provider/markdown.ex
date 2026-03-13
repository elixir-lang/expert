defmodule Expert.Provider.Markdown do
  @moduledoc """
  Utilities for formatting Markdown content.
  """

  alias GenLSP.Enumerations
  alias GenLSP.Structures.MarkupContent

  @type markdown :: String.t()

  @doc """
  Converts a string of Markdown into LSP markup content.
  """
  @spec to_content(markdown) :: MarkupContent.t()
  def to_content(markdown) when is_binary(markdown) do
    %MarkupContent{kind: Enumerations.MarkupKind.markdown(), value: markdown}
  end

  @doc """
  Wraps the content inside a Markdown code block.

  ## Options

    * `:lang` - The language for the block. Defaults to `"elixir"`.

  """
  @spec code_block(String.t(), [opt]) :: markdown
        when opt: {:lang, String.t()}
  def code_block(content, opts \\ []) do
    lang = Keyword.get(opts, :lang, "elixir")

    """
    ```#{lang}
    #{content}
    ```
    """
  end

  @doc """
  Creates a Markdown section with a header.

  ## Options

    * `:header` (required) - The section title.
    * `:header_level` - Defaults to `2`.

  """
  @spec section(markdown, [opt]) :: markdown
        when opt: {:header, markdown} | {:header_level, pos_integer()}
  def section(content, opts) do
    header = Keyword.fetch!(opts, :header)
    header_level = Keyword.get(opts, :header_level, 2)

    """
    #{String.duplicate("#", header_level)} #{header}

    #{content}
    """
  end

  @doc """
  Joins multiple Markdown sections.
  """
  @spec join_sections([markdown | nil]) :: markdown
  def join_sections(sections, joiner \\ "\n\n") when is_list(sections) do
    with_rules =
      sections
      |> Stream.filter(&(is_binary(&1) and &1 != ""))
      |> Stream.map(&String.trim/1)
      |> Enum.intersperse(joiner)

    case with_rules do
      [] -> ""
      _ -> IO.iodata_to_binary([with_rules, "\n"])
    end
  end

  @doc """
  Returns a string that can be used to join sections with a horizontal rule.
  """
  @spec separator() :: markdown
  def separator do
    "\n\n---\n\n"
  end
end
