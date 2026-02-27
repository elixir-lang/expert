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

  @doc """
  Checks if `file_path` is contained within `possible_parent`.

  ## Examples

      iex> Forge.Path.contains?("/home/user/project/lib/foo.ex", "/home/user/project")
      true

      iex> Forge.Path.contains?("/home/user/project", "/home/user/project")
      true

      iex> Forge.Path.contains?("/home/user/project_v2/lib/foo.ex", "/home/user/project")
      false

  """
  def contains?(file_path, possible_parent)
      when is_binary(file_path) and is_binary(possible_parent) do
    file_parts = file_path |> normalize() |> Path.split()
    parent_parts = possible_parent |> normalize() |> Path.split()

    List.starts_with?(file_parts, parent_parts)
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

      iex> Forge.Path.parent_path?("/home/user/docs_v2/file.txt", "/home/user/docs")
      false
  """
  def parent_path?(child_path, parent_path) when byte_size(child_path) < byte_size(parent_path) do
    false
  end

  def parent_path?(child_path, parent_path) do
    child_parts = child_path |> Path.expand() |> Path.split()
    parent_parts = parent_path |> Path.expand() |> Path.split()

    List.starts_with?(child_parts, parent_parts)
  end

  @spec expert_cache_dir() :: String.t()
  def expert_cache_dir do
    :user_cache
    |> :filename.basedir("expert")
    |> to_string()
  end
end
