defmodule Expert.Configuration.WorkspaceSymbols do
  @moduledoc false

  defstruct min_query_length: 2

  @type t :: %__MODULE__{
          min_query_length: non_neg_integer()
        }

  def new(settings \\ %{})

  def new(settings) when is_map(settings) do
    workspace_symbols_settings = Map.get(settings, "workspaceSymbols", %{})

    %__MODULE__{
      min_query_length: parse_min_query_length(workspace_symbols_settings)
    }
  end

  defp parse_min_query_length(%{"minQueryLength" => value})
       when is_integer(value) and value >= 0,
       do: value

  defp parse_min_query_length(_), do: 2
end
