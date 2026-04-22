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
end
