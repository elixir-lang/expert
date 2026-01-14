defmodule Forge.OS do
  def windows? do
    match?({:win32, _}, type())
  end

  # this is here to be mocked in tests
  def type do
    :os.type()
  end

  @doc """
  Normalizes a path to use forward slashes consistently.

  On Windows, Path.wildcard/1 has issues with mixed separator paths
  (e.g., "C:\\Users\\...\\Temp/briefly-.../lib/..."). This function
  ensures paths use forward slashes throughout, which works correctly
  with Path.wildcard on all platforms.
  """
  def normalize_path(path) when is_binary(path) do
    String.replace(path, "\\", "/")
  end
end
