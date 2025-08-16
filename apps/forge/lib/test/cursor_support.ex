defmodule Forge.Test.CursorSupport do
  @moduledoc """
  Utilities for extracting cursor position in code fragments and documents.
  """

  alias Forge.Document
  alias Forge.Document.Line
  alias Forge.Document.Position
  alias Forge.Test.PositionSupport

  import Line

  @default_cursor "|"
  @starting_line 1
  @starting_column 1

  @type cursor_position :: {pos_integer(), pos_integer()}

  @doc """
  Finds a cursor in `text` and returns a tuple of the cursor position and
  the text with the cursor stripped out.

  ## Options

    * `:cursor` - the cursor string to be found. Defaults to
      `#{inspect(@default_cursor)}`.

    * `:as` - one of `:text` (default) or `:document`. If `:document`,
      wraps the text in a `Forge.Document` using the URI `"file:///file.ex"`.

    * `:document` - the document path or URI. Setting this option implies
      `as: :document`.

  ## Examples

      iex> code = \"""
      ...> defmodule MyModule do
      ...>   alias Foo|
      ...> end
      ...> \"""

      iex> pop_cursor(code)
      {
        %Position{line: 2, column: 12},
        \"""
        defmodule MyModule do
          alias Foo
        end
        \"""
      }

      iex> pop_cursor(code, as: :document)
      {
        %Position{line: 2, column: 12},
        %Document{uri: "file:///file.ex", ...}
      }

      iex> pop_cursor(code, document: "my_doc.ex")
      {
        %Position{line: 2, column: 12},
        %Document{uri: "file:///my_doc.ex", ...}
      }

  """
  @spec pop_cursor(text :: String.t(), [opt]) ::
          {Position.t() | nil | :error, String.t() | Document.t()}
        when opt:
               {:cursor, String.t()}
               | {:as, :text | :document}
               | {:document, String.t()}
  def pop_cursor(text, opts \\ []) do
    as_document? = opts[:as] == :document or is_binary(opts[:document])

    position = cursor_position(text, Keyword.take(opts, [:cursor, :default_to_end]))
    stripped_text = strip_cursor(text, Keyword.take(opts, [:cursor]))

    if as_document? do
      uri =
        opts
        |> Keyword.get(:document, "file:///file.ex")
        |> Document.Path.ensure_uri()

      document = Document.new(uri, stripped_text, 0)
      position = position(document, position)
      {position, document}
    else
      position = position(position)
      {position, stripped_text}
    end
  end

  @doc """
  Strips all instances of `cursor` from `text`.
  """
  @spec strip_cursor(text :: String.t(), opts :: Keyword.t()) :: String.t()
  def strip_cursor(text, opts \\ []) do
    cursor = Keyword.get(opts, :cursor, @default_cursor)

    {_found, iodata} =
      text
      |> String.graphemes()
      |> Enum.chunk_every(2, 1, [""])
      |> Enum.reduce({false, []}, fn
        # don't strip the pipe in a `|>` operator when using the default cursor
        ["|", ">"], {found?, iodata} ->
          {found?, [iodata, "|"]}

        [^cursor, _lookahead], {false, iodata} ->
          {true, iodata}

        [c, _], {found?, iodata} ->
          {found?, [iodata, c]}
      end)

    IO.iodata_to_binary(iodata)
  end

  def decorate_cursor(%Document{} = document, %Position{} = position) do
    replace_line = position.line

    document.lines
    |> Enum.map(fn
      line(line_number: ^replace_line, text: text, ending: ending) ->
        {leading, trailing} = String.split_at(text, position.character - 1)

        leading = String.pad_leading(leading, position.character - 1)

        [leading, "|", trailing, ending]

      line(text: text, ending: ending) ->
        [text, ending]
    end)
    |> IO.iodata_to_binary()
  end

  defp cursor_position(text, opts) do
    cursor = Keyword.get(opts, :cursor, @default_cursor)
    default_to_end? = Keyword.get(opts, :default_to_end, true)

    {found?, position} =
      text
      |> String.graphemes()
      |> Enum.chunk_every(2, 1, [""])
      |> Enum.reduce_while({false, {@starting_line, @starting_column}}, fn
        # don't consider the pipe in a `|>` operator when using the default cursor
        ["|", ">"], {found?, {line, column}} ->
          {:cont, {found?, {line, column + 1}}}

        [^cursor, _], {_, position} ->
          {:halt, {true, position}}

        ["\n", _], {found?, {line, _column}} ->
          {:cont, {found?, {line + 1, @starting_column}}}

        _, {found?, {line, column}} ->
          {:cont, {found?, {line, column + 1}}}
      end)

    if found? or default_to_end? do
      position
    else
      nil
    end
  end

  defp position(%Document{} = document, {line, column})
       when is_number(line) and is_number(column) do
    Position.new(document, line, column)
  end

  defp position(%Document{}, nil), do: nil

  defp position({line, column}) when is_number(line) and is_number(column) do
    PositionSupport.position(line, column)
  end

  defp position(_), do: nil
end
