defmodule Mix.Credo do
  def dependency do
    {:credo, "~> 1.7", only: [:dev, :test]}
  end

  def config(opts \\ []) do
    included = Keyword.get(opts, :included, [])
    excluded = Keyword.get(opts, :excluded, [])

    %{
      configs: [
        %{
          name: "default",
          files: %{
            included: ["lib/", "src/", "test/" | included],
            excluded: excluded
          },
          plugins: [],
          requires: [],
          strict: true,
          parse_timeout: 5000,
          color: true,
          checks: [
            {Credo.Check.Design.AliasUsage,
             if_nested_deeper_than: 3, if_called_more_often_than: 1},
            {Credo.Check.Readability.AliasOrder, false},
            {Credo.Check.Readability.ModuleDoc, false},
            {Credo.Check.Readability.PreferImplicitTry, false},
            {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 10},
            {Credo.Check.Refactor.Nesting, max_nesting: 3},
            {Credo.Check.Refactor.PipeChainStart, []},
            {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false}
          ]
        }
      ]
    }
  end

  def absolute_path(relative_path) do
    __ENV__.file
    |> Path.dirname()
    |> Path.join(relative_path)
  end
end
