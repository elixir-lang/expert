defmodule Engine.Build.Document do
  alias Engine.Build
  alias Engine.Build.Document.Compilers
  alias Engine.Build.Isolation
  alias Forge.Document

  @compilers [Compilers.Config, Compilers.Elixir, Compilers.EEx, Compilers.HEEx, Compilers.NoOp]

  def compile(%Document{} = document) do
    compiler = Enum.find(@compilers, & &1.recognizes?(document))
    compile_fun = fn -> compiler.compile(document) end

    case Isolation.invoke(compile_fun) do
      {:ok, result} ->
        result

      {:error, {exception, stack}} ->
        diagnostic = Build.Error.error_to_diagnostic(document, exception, stack, nil)
        diagnostics = Build.Error.refine_diagnostics([diagnostic])
        {:error, diagnostics}
    end
  end
end
