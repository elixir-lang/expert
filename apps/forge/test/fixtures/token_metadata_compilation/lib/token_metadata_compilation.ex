defmodule TokenMetadataCompilation.Stringifier do
  defmacro stringify_case({:case, metadata, [expression, _clauses]}) do
    Macro.to_string({:case, metadata, [expression, expression]})
    expression
  end
end

defmodule TokenMetadataCompilation do
  require TokenMetadataCompilation.Stringifier

  def compile(target) do
    TokenMetadataCompilation.Stringifier.stringify_case(
      case target do
        _ -> target
      end
    )
  end
end
