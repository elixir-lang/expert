defmodule Expert.Protocol.Id do
  def next do
    [:monotonic, :positive]
    |> System.unique_integer()
  end
end
