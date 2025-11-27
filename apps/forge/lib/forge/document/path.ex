defmodule Forge.Document.Path do
  @moduledoc """
  A collection of functions dealing with converting filesystem paths to URIs and back
  """
  @file_scheme "file"

  @type uri_or_path :: Forge.uri() | Forge.path()

  @doc """
  Given a uri or a path, either return the uri unmodified or converts the path to a uri
  """
  @spec ensure_uri(uri_or_path()) :: Forge.uri()
  def ensure_uri("file://" <> _ = uri), do: uri

  def ensure_uri("untitled:" <> _ = uri), do: uri

  def ensure_uri(path), do: to_uri(path)

  @doc """
  Given a uri or a path, either return the path unmodified or converts the uri to a path
  """
  @spec ensure_path(uri_or_path()) :: Forge.path()
  def ensure_path("file://" <> _ = uri), do: from_uri(uri)

  def ensure_path(path) when is_binary(path), do: path

  @doc """
  Returns path from URI in a way that handles windows file:///c%3A/... URLs correctly
  """
  def from_uri(%URI{scheme: @file_scheme, path: nil}) do
    # treat no path as root path
    convert_separators_to_native("/")
  end

  def from_uri(%URI{scheme: @file_scheme, path: path, authority: authority})
      when path != "" and authority not in ["", nil] do
    decoded_authority = URI.decode(authority)
    decoded_path = URI.decode(path)

    if Forge.OS.windows?() and String.match?(decoded_authority, ~r/^[a-zA-Z]:$/) do
      convert_separators_to_native("#{decoded_authority}#{decoded_path}")
    else
      convert_separators_to_native("//#{decoded_authority}#{decoded_path}")
    end
  end

  def from_uri(%URI{scheme: @file_scheme, path: path}) do
    decoded_path = URI.decode(path)

    path =
      if Forge.OS.windows?() and String.match?(decoded_path, ~r/^\/[a-zA-Z]:/) do
        # Windows drive letter path
        # drop leading `/` and downcase drive letter
        <<"/", letter::binary-size(1), path_rest::binary>> = decoded_path
        "#{String.downcase(letter)}#{path_rest}"
      else
        decoded_path
      end

    convert_separators_to_native(path)
  end

  # `untitled:` URIs are used for unsaved files in vscode.
  def from_uri(%URI{scheme: "untitled"} = uri) when uri.path !== nil do
    URI.to_string(uri)
  end

  def from_uri(%URI{scheme: scheme}) do
    raise ArgumentError, message: "unsupported URI scheme #{inspect(scheme)}"
  end

  def from_uri(uri) do
    uri |> URI.parse() |> from_uri()
  end

  def absolute_from_uri(uri) do
    uri |> from_uri() |> Path.absname()
  end

  @doc """
  Converts a path into a URI
  """
  def to_uri(path) do
    path =
      path
      |> Path.expand()
      |> convert_separators_to_universal()

    {authority, path} =
      case path do
        "//" <> rest ->
          # UNC path - extract authority
          case String.split(rest, "/", parts: 2) do
            [_] ->
              # no path part, use root path
              {rest, "/"}

            [authority, ""] ->
              # empty path part, use root path
              {authority, "/"}

            [authority, p] ->
              {authority, "/" <> p}
          end

        "/" <> _rest ->
          {"", path}

        other ->
          # treat as relative to root path
          {"", "/" <> other}
      end

    %URI{
      scheme: @file_scheme,
      authority: authority |> URI.encode(),
      # file system paths allow reserved URI characters that need to be escaped
      # the exact rules are complicated but for simplicity we escape all reserved except `/`
      # that's what https://github.com/microsoft/vscode-uri does
      path: path |> URI.encode(&(&1 == ?/ or URI.char_unreserved?(&1)))
    }
    |> URI.to_string()
  end

  defp convert_separators_to_native(path) do
    if Forge.OS.windows?() do
      # convert path separators from URI to Windows
      String.replace(path, ~r/\//, "\\")
    else
      path
    end
  end

  defp convert_separators_to_universal(path) do
    if Forge.OS.windows?() do
      # convert path separators from Windows to URI
      String.replace(path, ~r/\\/, "/")
    else
      path
    end
  end
end
