defmodule Forge.Path do
  @moduledoc """
  Path utilities with cross-platform compatibility fixes.

  This module provides path handling functions that work consistently
  across Windows, macOS, and Linux, particularly for glob patterns
  which have platform-specific quirks.
  """

  def wildcard_pattern(path_segments) when is_list(path_segments) do
    path_segments
    |> Path.join()
  end

  def glob(path_segments) when is_list(path_segments) do
    path_segments
    |> wildcard_pattern()
    |> normalize()
    |> Path.wildcard()
  end

  def normalize(path) when is_binary(path) do
    String.replace(path, "\\", "/")
  end

  def contains?(file_path, possible_parent)
      when is_binary(file_path) and is_binary(possible_parent) do
    normalized_file = normalize(file_path)
    normalized_parent = normalize(possible_parent)
    String.starts_with?(normalized_file, normalized_parent)
  end

  def normalize_paths(paths) when is_list(paths) do
    Enum.map(paths, &normalize/1)
  end
end
