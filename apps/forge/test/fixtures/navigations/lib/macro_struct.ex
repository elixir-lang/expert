defmodule MacroStruct do
  defmacro __using__(_) do
    Module.register_attribute(__CALLER__.module, :field_names, accumulate: true)

    quote do
      import(unquote(__MODULE__), only: [field: 2, typedstruct: 2])
    end
  end

  defmacro __before_compile__(_) do
    fields = __CALLER__.module |> Module.get_attribute(:field_names) |> List.wrap()

    quote do
      defstruct unquote(fields)
    end
  end

  defmacro typedstruct(opts, do: body) do
    Module.put_attribute(__CALLER__.module, :opts, opts)

    quote do
      defmodule unquote(opts[:module]) do
        @before_compile unquote(__MODULE__)
        unquote(body)
      end
    end
  end

  defmacro field(name, _type) do
    Module.put_attribute(__CALLER__.module, :field_names, name)
  end
end
