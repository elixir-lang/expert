defmodule Engine.Build.CaptureIO do
  # Shamelessly stolen from ExUnit's CaptureIO
  alias Engine.Build

  def capture_io(fun) when is_function(fun, 0) do
    capture_io(:stdio, [], fun)
  end

  def capture_io(device, fun) when is_atom(device) and is_function(fun, 0) do
    capture_io(device, [], fun)
  end

  def capture_io(input, fun) when is_binary(input) and is_function(fun, 0) do
    capture_io(:stdio, [input: input], fun)
  end

  def capture_io(options, fun) when is_list(options) and is_function(fun, 0) do
    capture_io(:stdio, options, fun)
  end

  def capture_io(device, input, fun)
      when is_atom(device) and is_binary(input) and is_function(fun, 0) do
    capture_io(device, [input: input], fun)
  end

  def capture_io(device, options, fun)
      when is_atom(device) and is_list(options) and is_function(fun, 0) do
    do_capture_io(map_dev(device), options, fun)
  end

  defp map_dev(:stdio), do: :standard_io
  defp map_dev(:stderr), do: :standard_error
  defp map_dev(other), do: other

  defp do_capture_io(:standard_io, options, fun) do
    prompt_config = Keyword.get(options, :capture_prompt, true)
    encoding = Keyword.get(options, :encoding, :unicode)
    input = Keyword.get(options, :input, "")

    original_gl = Process.group_leader()
    {:ok, capture_gl} = StringIO.open(input, capture_prompt: prompt_config, encoding: encoding)

    try do
      Process.group_leader(self(), capture_gl)
      do_capture_gl(capture_gl, fun)
    after
      Process.group_leader(self(), original_gl)
    end
  end

  defp do_capture_io(device, options, fun) do
    input = Keyword.get(options, :input, "")
    encoding = Keyword.get(options, :encoding, :unicode)

    case Build.CaptureServer.device_capture_on(device, encoding, input) do
      {:ok, ref} ->
        try do
          result = fun.()
          output = Build.CaptureServer.device_output(device, ref)
          {output, result}
        rescue
          e ->
            output = Build.CaptureServer.device_output(device, ref)
            {output, {:exception, e}}
        after
          Build.CaptureServer.device_capture_off(ref)
        end

      {:error, :no_device} ->
        raise "could not find IO device registered at #{inspect(device)}"

      {:error, {:changed_encoding, current_encoding}} ->
        raise ArgumentError, """
        attempted to change the encoding for a currently captured device #{inspect(device)}.

        Currently set as: #{inspect(current_encoding)}
        Given: #{inspect(encoding)}

        If you need to use multiple encodings on a captured device, you cannot \
        run your test asynchronously
        """

      {:error, :input_on_already_captured_device} ->
        raise ArgumentError,
              "attempted multiple captures on device #{inspect(device)} with input. " <>
                "If you need to give an input to a captured device, you cannot run your test asynchronously"
    end
  end

  defp do_capture_gl(string_io, fun) do
    try do
      fun.()
    catch
      kind, reason ->
        {:ok, {_input, output}} = StringIO.close(string_io)
        {output, {kind, reason}}
    else
      result ->
        {:ok, {_input, output}} = StringIO.close(string_io)
        {output, result}
    end
  end
end
