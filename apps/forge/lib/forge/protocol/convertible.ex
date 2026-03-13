defmodule Forge.Protocol.Convertible.Helpers do
  @moduledoc false

  alias Forge.Document

  def apply(%{} = map, func) do
    result =
      Enum.reduce_while(map, [], fn {key, value}, acc ->
        case func.(value) do
          {:ok, native} ->
            {:cont, [{key, native} | acc]}

          error ->
            {:halt, error}
        end
      end)

    case result do
      l when is_list(l) ->
        {:ok, Map.new(l)}

      other ->
        other
    end
  end

  def apply(enumerable, func) do
    result =
      Enum.reduce_while(enumerable, [], fn elem, acc ->
        case func.(elem) do
          {:ok, native} ->
            {:cont, [native | acc]}

          error ->
            {:halt, error}
        end
      end)

    case result do
      l when is_list(l) ->
        {:ok, Enum.reverse(l)}

      error ->
        error
    end
  end

  def apply(%{} = map, func, context_document) do
    Enum.reduce_while(map, [], fn {key, value}, acc ->
      context_document = Document.Container.context_document(value, context_document)

      case func.(value, context_document) do
        {:ok, native} ->
          {:cont, [{key, native} | acc]}

        error ->
          {:halt, error}
      end
    end)
  end

  def apply(enumerable, func, context_document) do
    result =
      Enum.reduce_while(enumerable, [], fn elem, acc ->
        context_document = Document.Container.context_document(elem, context_document)

        case func.(elem, context_document) do
          {:ok, native} ->
            {:cont, [native | acc]}

          error ->
            {:halt, error}
        end
      end)

    case result do
      l when is_list(l) ->
        Enum.reverse(l)

      error ->
        error
    end
  end
end

defprotocol Forge.Protocol.Convertible do
  @moduledoc """
  A protocol that details conversions to and from Language Server idioms

  The [Language Server specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
  defines a couple of data structures that differ wildly from similar data structures and concepts in Elixir. Among these are
  positions and ranges. Elixir's parser thinks in terms of UTF-8 graphemes and uses one-based line and column numbers, while the
  language server speaks in UTF-16 code unit offsets and uses zero-based line and character (a misnomer, in reality this is a
  UTF-16 code unit) offsets. If not handled centrally, this leads to a profusion of conversion code throughout the language
  server codebase.

  That's where this protocol comes in. Using this protocol allows us to define native `Forge.Document.Position` and
  `Forge.Document.Range` structs and have them automatically convert into their Language Server counterparts, centralizing
  the conversion logic in a single pace.

  Note: You do not need to do conversions manually, If you define a new type, it is sufficient to implement this
  protocol for your new type
  """
  alias Forge.Document

  @fallback_to_any true

  @typedoc "Any type that can be converted using this protocol"
  @type t :: term()

  @typedoc "A native term that contains ranges, positions or both"
  @type native :: term()

  @typedoc "A Language server term"
  @type lsp :: term()

  @typedoc "The result of converting a lsp term into a native term"
  @type native_response :: {:ok, native()} | {:error, term}

  @typedoc "The result of converting a native term into a lsp term"
  @type lsp_response :: {:ok, lsp()} | {:error, term}

  @doc """
  Converts the structure to a native implementation
  """
  @spec to_native(t, Document.Container.maybe_context_document()) :: native_response()
  def to_native(t, context_document)

  @doc """
  Converts the native representation to a LSP compatible struct
  """
  @spec to_lsp(t) :: lsp_response()
  def to_lsp(t)
end

defimpl Forge.Protocol.Convertible, for: List do
  alias Forge.Protocol.Convertible
  alias Forge.Protocol.Convertible.Helpers

  def to_native(l, context_document) do
    case Helpers.apply(l, &Convertible.to_native/2, context_document) do
      l when is_list(l) ->
        {:ok, l}

      error ->
        error
    end
  end

  def to_lsp(l) do
    Helpers.apply(l, &Convertible.to_lsp/1)
  end
end

defimpl Forge.Protocol.Convertible, for: Map do
  alias Forge.Protocol.Convertible
  alias Forge.Protocol.Convertible.Helpers

  def to_native(map, context_document) do
    case Helpers.apply(map, &Convertible.to_native/2, context_document) do
      l when is_list(l) -> {:ok, Map.new(l)}
      error -> error
    end
  end

  def to_lsp(map) do
    Helpers.apply(map, &Convertible.to_lsp/1)
  end
end

defimpl Forge.Protocol.Convertible, for: Any do
  alias Forge.Document
  alias Forge.Protocol.Convertible
  alias Forge.Protocol.Convertible.Helpers

  def to_native(%_struct_module{} = struct, context_document) do
    context_document = Document.Container.context_document(struct, context_document)

    result =
      struct
      |> Map.from_struct()
      |> Helpers.apply(&Convertible.to_native/2, context_document)

    case result do
      l when is_list(l) ->
        {:ok, Map.merge(struct, Map.new(l))}

      error ->
        error
    end
  end

  def to_native(any, _context_document) do
    {:ok, any}
  end

  def to_lsp(%_struct_module{} = struct) do
    result =
      struct
      |> Map.from_struct()
      |> Helpers.apply(&Convertible.to_lsp/1)

    case result do
      {:ok, map} ->
        {:ok, Map.merge(struct, map)}

      error ->
        error
    end
  end

  def to_lsp(any) do
    {:ok, any}
  end
end
