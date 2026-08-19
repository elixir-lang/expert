defmodule Engine.Compilation.TracerTest do
  use ExUnit.Case, async: false
  use Patch

  alias Engine.Compilation.TraceBuffer
  alias Engine.Compilation.Tracer
  alias Forge.Formats
  alias Forge.Search.Indexer.Entry

  @moduletag :tmp_dir

  setup do
    start_supervised!(Engine.ApplicationCache)
    start_supervised!(TraceBuffer)
    patch(Engine, :broadcast, fn _message -> :ok end)
    :ok = TraceBuffer.discard()
    compiler_options = Code.compiler_options()

    on_exit(fn ->
      Code.compiler_options(compiler_options)
    end)

    :ok
  end

  test "records compiler-resolved definitions with foreign macro contexts", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    provider = Module.concat(__MODULE__, :"Provider#{suffix}")
    outer = Module.concat(__MODULE__, :"Outer#{suffix}")
    enabled = Module.concat(__MODULE__, :"Enabled#{suffix}")
    disabled = Module.concat(__MODULE__, :"Disabled#{suffix}")
    path = Path.join(tmp_dir, "definitions.ex")

    source = """
    defmodule #{inspect(provider)} do
      defmacro __using__(opts) do
        name = Keyword.fetch!(opts, :name)
        enabled? = Keyword.fetch!(opts, :enabled?)

        quote do
          if unquote(enabled?) do
            def unquote(name)(argument), do: argument
          end
        end
      end
    end

    defmodule #{inspect(outer)} do
      defmacro __using__(opts) do
        quote do
          use #{inspect(provider)}, unquote(opts)
        end
      end
    end

    defmodule #{inspect(enabled)} do
      use #{inspect(outer)}, name: :generated_name, enabled?: true
    end

    defmodule #{inspect(disabled)} do
      use #{inspect(outer)}, name: :not_generated, enabled?: false
    end
    """

    File.write!(path, source)
    compiler_options = Code.compiler_options()
    tracers = Access.get(compiler_options, :tracers, [])

    Code.compiler_options(debug_info: true, tracers: Enum.uniq([Tracer | tracers]))

    Code.compile_file(path)

    native_path = Forge.Path.native(path)

    assert {:ok, %{^native_path => entries}} = TraceBuffer.drain_definitions()

    assert %Entry{
             subject: generated_subject,
             type: {:function, :public},
             metadata: %{via: :use, original_mfa: original_mfa},
             range: %{start: %{line: line}}
           } =
             Enum.find(entries, fn
               %Entry{subject: subject, metadata: %{via: :use}} ->
                 subject == Formats.mfa(enabled, :generated_name, 1)

               _ ->
                 false
             end)

    assert generated_subject == Formats.mfa(enabled, :generated_name, 1)
    assert original_mfa == Formats.mfa(provider, :generated_name, 1)
    assert line == source_line(source, "use #{inspect(outer)}, name: :generated_name")

    refute Enum.any?(entries, fn entry ->
             entry.subject == Formats.mfa(disabled, :not_generated, 1)
           end)

    refute Enum.any?(entries, fn
             %Entry{metadata: %{original_mfa: original_mfa, via: :use}} ->
               original_mfa == Formats.mfa(nil, :__using__, 1)

             _ ->
               false
           end)
  end

  defp source_line(source, text) do
    source
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end
end
