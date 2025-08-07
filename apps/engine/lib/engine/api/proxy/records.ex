defmodule Engine.Api.Proxy.Records do
  alias Forge.Formats

  import Record

  defrecord :mfa, module: nil, function: nil, arguments: [], seq: nil

  def mfa(module, function, arguments) do
    mfa(
      module: module,
      function: function,
      arguments: arguments,
      seq: System.unique_integer([:monotonic])
    )
  end

  defmacro to_mfa(ast) do
    {m, f, a} = Macro.decompose_call(ast)
    module = Macro.expand(m, __CALLER__)
    arity = length(a)

    Code.ensure_compiled!(module)
    Code.ensure_loaded!(module)

    unless function_exported?(module, f, arity) do
      mfa = Formats.mfa(module, f, arity)

      raise CompileError.message(%{
              file: __CALLER__.file,
              line: __CALLER__.line,
              description: "No function named #{mfa} defined. Proxy will fail"
            })
    end

    quote(do: unquote(__MODULE__).mfa(unquote(m), unquote(f), unquote(a)))
  end
end
