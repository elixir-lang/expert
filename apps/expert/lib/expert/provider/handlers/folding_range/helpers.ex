defmodule Expert.Provider.Handlers.FoldingRange.Helpers do
  @moduledoc false

  def first_and_last_of_list([]), do: :empty_list

  def first_and_last_of_list([head]), do: {head, head}

  def first_and_last_of_list([head, last]), do: {head, last}

  def first_and_last_of_list([head | tail]) do
    {head, List.last(tail)}
  end
end
