defmodule Expert.Provider.Handler do
  @moduledoc """
  Behaviour for LSP request and notification handlers.
  """

  alias Expert.Document.Context

  @doc """
  Handles an LSP request or notification.

  Returns `{:ok, response}` on success, or `{:error, reason}` on failure.
  For notifications that don't require a response, return `{:ok, nil}`.
  """
  @callback handle(request :: struct(), context :: Context.t() | nil) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Returns whether the handler requires the engine to be initialized before
  it can handle a request. Defaults to `true`.

  Handlers that operate purely on the document text (e.g. folding range) can
  override this to `false` so they are not blocked during engine startup.
  """
  @callback requires_engine?() :: boolean()

  @optional_callbacks requires_engine?: 0

  @doc "Returns the value of `requires_engine?/0`, defaulting to `true`."
  @spec requires_engine?(module()) :: boolean()
  def requires_engine?(handler) do
    handler.requires_engine?()
  rescue
    UndefinedFunctionError -> true
  end
end
