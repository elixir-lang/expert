defmodule Expert.Configuration do
  @moduledoc """
  Encapsulates expert configuration options and client capability support.
  """

  alias Expert.Configuration.Support
  alias Expert.Configuration.WorkspaceSymbols
  alias Expert.Dialyzer
  alias Expert.Protocol.Id
  alias GenLSP.Notifications.WorkspaceDidChangeConfiguration
  alias GenLSP.Requests
  alias GenLSP.Structures

  defstruct support: nil,
            client_name: nil,
            additional_watched_extensions: nil,
            dialyzer_enabled?: false,
            workspace_symbols: %WorkspaceSymbols{}

  @type t :: %__MODULE__{
          support: support | nil,
          client_name: String.t() | nil,
          additional_watched_extensions: [String.t()] | nil,
          dialyzer_enabled?: boolean(),
          workspace_symbols: WorkspaceSymbols.t()
        }

  @opaque support :: Support.t()

  @dialyzer {:nowarn_function, set_dialyzer_enabled: 2}

  @spec new(Structures.ClientCapabilities.t(), String.t() | nil) :: t
  def new(%Structures.ClientCapabilities{} = client_capabilities, client_name) do
    support = Support.new(client_capabilities)

    %__MODULE__{support: support, client_name: client_name}
  end

  @spec new(keyword()) :: t
  def new(attrs \\ []) do
    struct!(__MODULE__, [support: Support.new()] ++ attrs)
  end

  @spec set(t) :: t
  def set(%__MODULE__{} = config) do
    :persistent_term.put(__MODULE__, config)
    config
  end

  @spec get() :: t
  def get do
    :persistent_term.get(__MODULE__, nil) || struct!(__MODULE__, support: Support.new())
  end

  @spec client_support(atom()) :: term()
  def client_support(key) when is_atom(key) do
    client_support(get().support, key)
  end

  defp client_support(%Support{} = client_support, key) do
    case Map.fetch(client_support, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "unknown key: #{inspect(key)}"
    end
  end

  @spec default() :: {:ok, t} | {:ok, t, Requests.ClientRegisterCapability.t()}
  def default do
    apply_config_change(get(), %{})
  end

  @spec on_change(WorkspaceDidChangeConfiguration.t() | :defaults) ::
          {:ok, t}
          | {:ok, t, Requests.ClientRegisterCapability.t()}
  def on_change(:defaults) do
    apply_config_change(get(), %{})
  end

  def on_change(%WorkspaceDidChangeConfiguration{} = change) do
    apply_config_change(get(), change.params.settings)
  end

  defp apply_config_change(%__MODULE__{} = old_config, %{} = settings) do
    new_config =
      old_config
      |> set_dialyzer_enabled(settings)
      |> set_workspace_symbols(settings)
      |> set()

    maybe_watched_extensions_request(new_config, settings)
  end

  defp set_dialyzer_enabled(%__MODULE__{} = old_config, settings) do
    enabled? =
      if Dialyzer.check_support() == :ok do
        Map.get(settings, "dialyzerEnabled", true)
      else
        false
      end

    %__MODULE__{old_config | dialyzer_enabled?: enabled?}
  end

  defp set_workspace_symbols(%__MODULE__{} = config, settings) do
    %__MODULE__{config | workspace_symbols: WorkspaceSymbols.new(settings)}
  end

  defp maybe_watched_extensions_request(
         %__MODULE__{} = config,
         %{"additionalWatchedExtensions" => []}
       ) do
    {:ok, config}
  end

  defp maybe_watched_extensions_request(
         %__MODULE__{} = config,
         %{"additionalWatchedExtensions" => extensions}
       )
       when is_list(extensions) do
    register_id = Id.next()
    request_id = Id.next()

    watchers = Enum.map(extensions, fn ext -> %{"globPattern" => "**/*#{ext}"} end)

    registration =
      %Structures.Registration{
        id: request_id,
        method: "workspace/didChangeWatchedFiles",
        register_options: %{"watchers" => watchers}
      }

    request = %Requests.ClientRegisterCapability{
      id: register_id,
      params: %Structures.RegistrationParams{registrations: [registration]}
    }

    {:ok, config, request}
  end

  defp maybe_watched_extensions_request(%__MODULE__{} = config, _settings) do
    {:ok, config}
  end
end
