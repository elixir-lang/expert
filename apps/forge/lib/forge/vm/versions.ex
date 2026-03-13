defmodule Forge.VM.Versions do
  @moduledoc """
  Reads and writes version tags for elixir and erlang

  When compiling, it is important to node which version of the VM and elixir runtime
  were used to build the beam files, as beam files compiled on a newer version of the
  VM cannot be used on older versions.

  This module allows a directory to be tagged with the versions of elixir and erlang
  used as compilation artifacts, and also allows the user to ask if a certain version
  is compatible with the currently running VM.
  """

  @type version_string :: String.t()

  @type t :: %{elixir: version_string(), erlang: version_string()}
  @type versioned_t :: %{elixir: Version.t(), erlang: Version.t()}

  defmacrop cache_in_persistent_term(key, do: materializer) do
    quote do
      with :not_found <- :persistent_term.get(unquote(key), :not_found) do
        result = unquote(materializer)
        :persistent_term.put(unquote(key), result)
        result
      end
    end
  end

  @doc """
  Returns the versions of elixir and erlang in the currently running VM
  """
  @spec current() :: t
  def current do
    %{
      elixir: elixir_version(),
      erlang: erlang_version()
    }
  end

  @doc """
  Returns true if the current version of elixir matches the requirement
  """
  def current_elixir_matches?(requirement) do
    cache_in_persistent_term {:current_elixir_matches?, requirement} do
      Version.match?(elixir_version(), requirement)
    end
  end

  @doc """
  Returns the compiled-in versions of elixir and erlang.

  This function uses the code server to find `.elixir` and `.erlang` files in the code path.
  Each of these files represent the version of the runtime the artifact was compiled with.
  """
  @spec compiled() :: {:ok, t} | {:error, term()}
  def compiled do
    with {:ok, elixir_path} <- code_find_file(version_file(:elixir)),
         {:ok, erlang_path} <- code_find_file(version_file(:erlang)),
         {:ok, elixir_version} <- read_file(elixir_path),
         {:ok, erlang_version} <- read_file(erlang_path) do
      {:ok, %{elixir: String.trim(elixir_version), erlang: String.trim(erlang_version)}}
    end
  end

  @doc """
  Converts the values of a version map into `Version` structs
  """
  @spec to_versions(t) :: versioned_t()
  def to_versions(%{elixir: elixir, erlang: erlang}) do
    %{elixir: to_version(elixir), erlang: to_version(erlang)}
  end

  @doc """
  Tells whether or not the current version of VM is supported by
  Expert's compiled artifacts.
  """
  @spec compatible?() :: boolean
  @spec compatible?(Path.t()) :: boolean
  def compatible? do
    case code_find_file(version_file(:erlang)) do
      {:ok, path} ->
        path
        |> Path.dirname()
        |> compatible?()

      _ ->
        false
    end
  end

  def compatible?(directory) do
    system = current()

    case read(directory) do
      {:ok, tagged} ->
        system_erlang = to_version(system.erlang)
        tagged_erlang = to_version(tagged.erlang)

        tagged_erlang.major <= system_erlang.major

      _ ->
        false
    end
  end

  @doc """
  Returns true if the current directory has version tags for
  both elixir and erlang in it.
  """
  def tagged?(directory) do
    if File.exists?(version_file_path(directory, :elixir)) do
      File.exists?(version_file_path(directory, :erlang))
    end
  end

  @doc """
  Writes version tags in the given directory, overwriting any that are present
  """
  def write(directory) do
    write_erlang_version(directory)
    write_elixir_version(directory)
  end

  @doc """
  Reads all the version tags in the given directory.
  This function will fail if one or both tags is missing
  """
  def read(directory) do
    with {:ok, elixir} <- read_elixir_version(directory),
         {:ok, erlang} <- read_erlang_version(directory) do
      {:ok, %{elixir: String.trim(elixir), erlang: String.trim(erlang)}}
    end
  end

  defp write_erlang_version(directory) do
    directory
    |> version_file_path(:erlang)
    |> write_file!(erlang_version())
  end

  defp write_elixir_version(directory) do
    directory
    |> version_file_path(:elixir)
    |> write_file!(elixir_version())
  end

  defp read_erlang_version(directory) do
    directory
    |> version_file_path(:erlang)
    |> read_file()
  end

  defp read_elixir_version(directory) do
    directory
    |> version_file_path(:elixir)
    |> read_file()
  end

  defp elixir_version do
    cache_in_persistent_term {__MODULE__, :current_elixir} do
      System.version()
    end
  end

  defp erlang_version do
    cache_in_persistent_term {__MODULE__, :current_erlang} do
      major = :otp_release |> :erlang.system_info() |> List.to_string()
      version_file = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])

      try do
        {:ok, contents} = read_file(version_file)
        String.split(contents, "\n", trim: true)
      else
        [full] -> full
        _ -> major
      catch
        :error ->
          major
      end
    end
  end

  defp version_file_path(directory, language) do
    Path.join(directory, version_file(language))
  end

  defp version_file(language) do
    ".#{language}"
  end

  defp normalize(erlang_version) do
    # Erlang doesn't use versions compabible with semantic versioning,
    # this will make it compatible, as whatever the last number represents
    # won't introduce vm-level incompatibilities.

    version_components =
      erlang_version
      |> String.split(".")
      |> Enum.take(3)

    normalized =
      case version_components do
        [major] -> [major, "0", "0"]
        [major, minor] -> [major, minor, "0"]
        [_, _, _] = version -> version
        [major, minor, patch | _] -> [major, minor, patch]
      end

    Enum.join(normalized, ".")
  end

  defp code_find_file(file_name) when is_binary(file_name) do
    file_name
    |> String.to_charlist()
    |> code_find_file()
  end

  defp code_find_file(file_name) when is_list(file_name) do
    case :code.where_is_file(file_name) do
      :non_existing ->
        {:error, {:file_missing, file_name}}

      path ->
        {:ok, List.to_string(path)}
    end
  end

  defp to_version(version) when is_binary(version) do
    version |> normalize() |> Version.parse!()
  end

  # these functions exist for testing. I was getting process killed with
  # patch if we patch the File module directly
  defp write_file!(path, contents) do
    File.write!(path, contents)
  end

  defp read_file(path) do
    File.read(path)
  end
end
