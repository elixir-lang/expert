defmodule Engine.Progress do
  @moduledoc """
  LSP progress reporting for engine operations.
  """

  use Forge.Progress

  alias Engine.Dispatch

  @impl true
  def begin(title, opts \\ []) when is_list(opts) do
    Dispatch.erpc_call(Expert.Progress, :begin, [title, opts])
  end

  @impl true
  def report(@noop_token, _opts), do: :ok

  def report(token, [_ | _] = opts) when is_token(token) do
    Dispatch.erpc_cast(Expert.Progress, :report, [token, opts])
  end

  @impl true
  def complete(token, opts \\ [])

  def complete(@noop_token, _opts), do: :ok

  def complete(token, opts) when is_token(token) and is_list(opts) do
    Dispatch.erpc_cast(Expert.Progress, :complete, [token, opts])
  end
end
