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

  @doc """
  Checks if the `parent_path` is a parent directory of the `child_path`.

  ## Examples

      iex> Forge.Path.parent_path?("/home/user/docs/file.txt", "/home/user")
      true

      iex> Forge.Path.parent_path?("/home/user/docs/file.txt", "/home/admin")
      false

      iex> Forge.Path.parent_path?("/home/user/docs", "/home/user/docs")
      true

      iex> Forge.Path.parent_path?("/home/user/docs", "/home/user/docs/subdir")
      false
  """
  def parent_path?(child_path, parent_path) when byte_size(child_path) < byte_size(parent_path) do
    false
  end

  def parent_path?(child_path, parent_path) do
    normalized_child = Path.expand(child_path)
    normalized_parent = Path.expand(parent_path)

    String.starts_with?(normalized_child, normalized_parent)
  end
end
