defmodule Forge.Document.Lines do
  @moduledoc """
  A hyper-optimized, line-based backing store for text documents
  """
  use Forge.StructAccess

  import Forge.Document.Line

  alias Forge.Document.LineParser

  @default_starting_index 1

  defstruct lines: nil, starting_index: @default_starting_index

  @type t :: %__MODULE__{}

  @doc """
  Create a new line store with the given text at the given starting index
  """
  @spec new(String.t(), non_neg_integer) :: t
  def new(text, starting_index \\ @default_starting_index) do
    lines =
      text
      |> LineParser.parse(starting_index)
      |> List.to_tuple()

    %__MODULE__{lines: lines, starting_index: starting_index}
  end

  @doc """
  Turnss a line store into an iolist
  """
  @spec to_iodata(t) :: iodata()
  def to_iodata(%__MODULE__{} = document) do
    reduce(document, [], fn line(text: text, ending: ending), acc ->
      [acc | [text | ending]]
    end)
  end

  @doc """
  Turns a line store into a string
  """
  def to_string(%__MODULE__{} = document) do
    document
    |> to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns the number of lines in the line store
  """
  def size(%__MODULE__{} = document) do
    tuple_size(document.lines)
  end

  @doc """
  Gets the current line with the given index using fetch semantics
  """
  def fetch_line(%__MODULE__{lines: lines, starting_index: starting_index}, index)
      when index - starting_index >= tuple_size(lines) or index < starting_index do
    :error
  end

  def fetch_line(%__MODULE__{lines: {}}, _) do
    :error
  end

  def fetch_line(%__MODULE__{} = document, index) when is_integer(index) do
    case elem(document.lines, index - document.starting_index) do
      line() = line -> {:ok, line}
      _ -> :error
    end
  end

  @doc false
  def reduce(%__MODULE__{} = document, initial, reducer_fn) do
    size = size(document)

    if size == 0 do
      initial
    else
      Enum.reduce(0..(size - 1), initial, fn index, acc ->
        document.lines
        |> elem(index)
        |> reducer_fn.(acc)
      end)
    end
  end
end

defimpl Inspect, for: Forge.Document.Lines do
  import Forge.Document.Line
  import Inspect.Algebra

  alias Forge.Document.Lines

  def inspect(%Lines{lines: {}}) do
    concat([empty(), "%Lines<empty>"])
  end

  def inspect(document, opts) do
    document_body =
      case Lines.fetch_line(document, 1) do
        {:ok, line(text: text)} ->
          concat(empty(), to_doc(text <> "...", opts))

        :error ->
          " empty "
      end

    line_or_lines =
      if Lines.size(document) == 1 do
        "line"
      else
        "lines"
      end

    concat([
      empty(),
      "%Lines<",
      document_body,
      "(",
      space(
        to_doc(Lines.size(document), opts),
        line_or_lines
      ),
      ")>"
    ])
  end
end

defimpl Enumerable, for: Forge.Document.Lines do
  alias Forge.Document.Lines

  def count(%Lines{} = document) do
    {:ok, Lines.size(document)}
  end

  def member?(%Lines{}, _) do
    {:error, Lines}
  end

  def reduce(%Lines{} = document, acc, fun) do
    tuple_reduce({0, tuple_size(document.lines), document.lines}, acc, fun)
  end

  def slice(%Lines{} = document) do
    slicing_function =
      fn start, len, step -> do_slice(document, start, len, step) end

    {:ok, Lines.size(document), slicing_function}
  end

  defp do_slice(%Lines{} = document, start, 1, _) do
    [elem(document.lines, start)]
  end

  defp do_slice(%Lines{} = document, start, length, step) do
    Enum.map(start..(start + length - 1)//step, &elem(document.lines, &1))
  end

  defp tuple_reduce(_, {:halt, acc}, _fun) do
    {:halted, acc}
  end

  defp tuple_reduce(current_state, {:suspend, acc}, fun) do
    {:suspended, acc, &tuple_reduce(current_state, &1, fun)}
  end

  defp tuple_reduce({same, same, _}, {:cont, acc}, _) do
    {:done, acc}
  end

  defp tuple_reduce({index, size, tuple}, {:cont, acc}, fun) do
    tuple_reduce({index + 1, size, tuple}, fun.(elem(tuple, index), acc), fun)
  end
end
