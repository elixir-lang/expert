defmodule Engine.Build.Error.Parse do
  alias Engine.Build.Error.Location
  alias Forge.Document
  alias Forge.Document.Range
  alias Forge.Plugin.V1.Diagnostic.Result

  @elixir_source "Elixir"

  # Parse errors happen during Code.string_to_quoted and are raised as SyntaxErrors, and TokenMissingErrors.
  def to_diagnostics(
        %Document{} = source,
        context,
        {_error, detail} = message_info,
        token
      )
      when is_binary(detail) do
    # NOTE: mainly for `unexpected token` errors `< 1.16`,
    # its details consist of multiple lines, so it is a tuple.
    detail_diagnostics = detail_diagnostics(source, detail)
    error = message_info_to_binary(message_info, token)
    error_diagnostics = to_diagnostics(source, context, error, token)
    Location.uniq(detail_diagnostics ++ error_diagnostics)
  end

  def to_diagnostics(%Document{} = source, context, message_info, token)
      when is_exception(message_info) do
    to_diagnostics(source, context, Exception.message(message_info), token)
  end

  def to_diagnostics(%Document{} = source, context, message_info, token) do
    {start_line_fn, end_line_fn} =
      if Features.details_in_context?() do
        {&build_end_line_diagnostics_from_context/4, &build_start_line_diagnostics_from_context/4}
      else
        {&build_start_line_diagnostics/4, &build_end_line_diagnostics/4}
      end

    parse_error_diagnostic_functions = [
      end_line_fn,
      start_line_fn,
      &build_hint_diagnostics/4
    ]

    parse_error_diagnostic_functions
    |> Enum.flat_map(& &1.(source, context, message_info, token))
    |> Location.uniq()
  end

  @missing_terminator_pattern ~r/missing terminator: \w+/
  defp build_end_line_diagnostics_from_context(
         %Document{} = source,
         context,
         message_info,
         token
       ) do
    message =
      cond do
        String.starts_with?(message_info, "unexpected") ->
          ~s/#{message_info}#{token}, expected `#{context[:expected_delimiter]}`/

        Regex.match?(@missing_terminator_pattern, message_info) ->
          [message] = Regex.run(@missing_terminator_pattern, message_info)
          message

        true ->
          "#{message_info}#{token}"
      end

    case Location.fetch_range(source, context) do
      {:ok, %Range{end: end_pos}} ->
        [
          Result.new(
            source.uri,
            {end_pos.line, end_pos.character},
            message,
            :error,
            @elixir_source
          )
        ]

      :error ->
        []
    end
  end

  defp build_end_line_diagnostics(%Document{} = source, context, message_info, token) do
    [end_line_message | _] = String.split(message_info, "\n")

    message =
      if String.ends_with?(end_line_message, token) do
        end_line_message
      else
        end_line_message <> token
      end

    diagnostic =
      Result.new(source.uri, Location.context_to_position(context), message, :error, "Elixir")

    [diagnostic]
  end

  defp build_start_line_diagnostics_from_context(
         %Document{} = source,
         context,
         message_info,
         token
       ) do
    opening_delimiter = context[:opening_delimiter]

    if opening_delimiter do
      build_opening_delimiter_diagnostics(source, context, opening_delimiter)
    else
      build_syntax_error_diagnostic(source, context, message_info, token)
    end
  end

  defp build_opening_delimiter_diagnostics(%Document{} = source, context, opening_delimiter) do
    message =
      ~s/The `#{opening_delimiter}` here is missing terminator `#{context[:expected_delimiter]}`/

    opening_delimiter_length = opening_delimiter |> Atom.to_string() |> String.length()

    pos =
      Location.range(
        source,
        context[:line],
        context[:column],
        context[:line],
        context[:column] + opening_delimiter_length
      )

    result = Result.new(source.uri, pos, message, :error, @elixir_source)
    [result]
  end

  defp build_syntax_error_diagnostic(%Document{} = source, context, message_info, token) do
    message = "#{message_info}#{token}"
    pos = Location.position(context[:line], context[:column])
    result = Result.new(source.uri, pos, message, :error, @elixir_source)
    [result]
  end

  @start_line_regex ~r/(\w+) \(for (.*) starting at line (\d+)\)/
  defp build_start_line_diagnostics(%Document{} = source, _context, message_info, _token) do
    case Regex.run(@start_line_regex, message_info) do
      [_, missing, token, start_line] ->
        message =
          ~s[The #{format_token(token)} here is missing terminator #{format_token(missing)}]

        position = String.to_integer(start_line)
        result = Result.new(source.uri, position, message, :error, @elixir_source)
        [result]

      _ ->
        []
    end
  end

  @hint_regex ~r/(HINT:|hint:\e\[0m|hint:)( .*on line (\d+).*)/m
  defp build_hint_diagnostics(%Document{} = source, _context, message_info, _token) do
    case Regex.run(@hint_regex, message_info) do
      [_whole_message, _hint, message, hint_line] ->
        message = "HINT:" <> String.replace(message, ~r/on line \d+/, "here")
        position = String.to_integer(hint_line)
        result = Result.new(source.uri, position, message, :error, @elixir_source)
        [result]

      _ ->
        []
    end
  end

  defp message_info_to_binary({header, footer}, token) do
    header <> token <> footer
  end

  @detail_location_re ~r/at line (\d+)/
  defp detail_diagnostics(%Document{} = source, detail) do
    case Regex.scan(@detail_location_re, detail) do
      [[matched, line_number]] ->
        line_number = String.to_integer(line_number)
        message = String.replace(detail, matched, "here")
        result = Result.new(source.uri, line_number, message, :error, @elixir_source)
        [result]

      _ ->
        []
    end
  end

  defp format_token(token) when is_binary(token) do
    if String.contains?(token, "\"") do
      String.replace(token, "\"", "`")
    else
      "`#{token}`"
    end
  end
end
