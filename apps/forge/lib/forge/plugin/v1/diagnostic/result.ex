defmodule Forge.Plugin.V1.Diagnostic.Result do
  @moduledoc """
  The result of a diagnostic run

  A diagnostic plugin emits a list of `Result` structs that inform the user about issues
  the plugin has found. The results contain the following keys:

  `uri` - The URI of the document where the error occurs. `Forge.Document` structs contain a
  `uri` field which can be used to fill out this field. If you have a filesystem path, the function
  `Forge.Document.Path.to_uri/1` can be used to transform a path to a URI.

  `message` - The diagnostic message displayed to the user

  `details` - Further details about the message

  `position` - Where the message occurred (see the `Positions` section for details)

  `severity` - How important the issue is. Can be one of (from least severe to most severe)
  `:hint`, `:information`, `:warning`, `:error`

  `source` - The name of the plugin that produced this as a human-readable string.


  ## Positions

  Diagnostics need to inform the language client where the error occurs. Positions are the
  mechanism they use to do so. Positions take several forms, which are:

  `line number` - If the position is a one-based line number, the diagnostic will refer to
  the entire flagged line

  `{line_number, column}` - If the position is a two-tuple of a one-based line number and a one-based
  column, then the diagnostic will begin on the line indicated, and start at the column indicated. The
  diagnostic will run to the end of the line.

  `{start_line, start_column, end_line, end_column}` - If the position is a four-tuple of of one-based
  line and column numbers, the diagnostic will start on `start_line` at `start_column` and run until
  `end_line` at `end_column`. This is the most detailed form of describing a position, and should be preferred
  to the others, as it will produce the most accurate highlighting of the diagnostic.

  `Document.Range.t` - Equivalent to the {start_line, start_column, end_line, end_column}, but saves a
  conversion step

  `Document.Position.t` - Equivalent to `{line_number, column}`, but saves a conversion step.
  """
  alias Forge.Document

  defstruct [:details, :message, :position, :severity, :source, :uri]

  @typedoc """
  A path or a uri.
  """
  @type path_or_uri :: Forge.path() | Forge.uri()

  @typedoc """
  The severity of the diagnostic.
  """
  @type severity :: :hint | :information | :warning | :error

  @typedoc false
  @type mix_position ::
          non_neg_integer()
          | {pos_integer(), non_neg_integer()}
          | {pos_integer(), non_neg_integer(), pos_integer(), non_neg_integer()}

  @typedoc """
  Where the error occurs in the document.
  """
  @type position :: mix_position() | Document.Range.t() | Document.Position.t()

  @typedoc """
  A result emitted by a diagnostic plugin.

  These results are displayed in the editor to the user.
  """
  @type t :: %__MODULE__{
          position: position,
          message: iodata(),
          severity: severity(),
          source: String.t(),
          uri: Forge.uri()
        }

  @doc """
  Creates a new diagnostic result.
  """
  @spec new(path_or_uri, position, iodata(), severity(), String.t()) :: t
  @spec new(path_or_uri, position, iodata(), severity(), String.t(), any()) :: t
  def new(maybe_uri_or_path, position, message, severity, source, details \\ nil) do
    uri =
      if maybe_uri_or_path do
        Document.Path.ensure_uri(maybe_uri_or_path)
      end

    message = IO.iodata_to_binary(message)

    %__MODULE__{
      uri: uri,
      position: position,
      message: message,
      source: source,
      severity: severity,
      details: details
    }
  end
end
