defmodule Forge.Diagnostic do
  @moduledoc """
  A diagnostic reported by the compiler or displayed to the user.

  Positions may be a one-based line number, a `{line, column}` tuple, a
  `{start_line, start_column, end_line, end_column}` tuple, or a
  `Forge.Document.Position` or `Forge.Document.Range`.
  """
  alias Forge.Document

  defstruct [:details, :message, :position, :severity, :source, :uri]

  @type path_or_uri :: Forge.path() | Forge.uri()
  @type severity :: :hint | :information | :warning | :error

  @type mix_position ::
          non_neg_integer()
          | {pos_integer(), non_neg_integer()}
          | {pos_integer(), non_neg_integer(), pos_integer(), non_neg_integer()}

  @type position :: mix_position() | Document.Range.t() | Document.Position.t()

  @type t :: %__MODULE__{
          position: position,
          message: iodata(),
          severity: severity(),
          source: String.t(),
          uri: Forge.uri()
        }

  @spec new(path_or_uri, position, iodata(), severity(), String.t()) :: t
  @spec new(path_or_uri, position, iodata(), severity(), String.t(), any()) :: t
  def new(maybe_uri_or_path, position, message, severity, source, details \\ nil) do
    uri =
      if maybe_uri_or_path do
        Document.Path.ensure_uri(maybe_uri_or_path)
      end

    %__MODULE__{
      uri: uri,
      position: position,
      message: IO.iodata_to_binary(message),
      source: source,
      severity: severity,
      details: details
    }
  end
end
