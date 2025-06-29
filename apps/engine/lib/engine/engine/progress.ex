defmodule Engine.Progress do
  import Forge.EngineApi.Messages

  @type label :: String.t()
  @type message :: String.t()

  @type delta :: pos_integer()
  @type on_complete_callback :: (-> any())
  @type report_progress_callback :: (delta(), message() -> any())

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__), only: [with_progress: 2]
    end
  end

  @spec with_progress(label(), (-> any())) :: any()
  def with_progress(label, func) when is_function(func, 0) do
    on_complete = begin_progress(label)

    try do
      func.()
    after
      on_complete.()
    end
  end

  @spec with_percent_progress(label(), pos_integer(), (report_progress_callback() -> any())) ::
          any()
  def with_percent_progress(label, max, func) when is_function(func, 1) do
    {report_progress, on_complete} = begin_percent(label, max)

    try do
      func.(report_progress)
    after
      on_complete.()
    end
  end

  @spec begin_progress(label :: label()) :: on_complete_callback()
  def begin_progress(label) do
    Engine.broadcast(project_progress(label: label, stage: :begin))

    fn ->
      Engine.broadcast(project_progress(label: label, stage: :complete))
    end
  end

  @spec begin_percent(label(), pos_integer()) ::
          {report_progress_callback(), on_complete_callback()}
  def begin_percent(label, max) do
    Engine.broadcast(percent_progress(label: label, max: max, stage: :begin))

    report_progress = fn delta, message ->
      Engine.broadcast(
        percent_progress(label: label, message: message, delta: delta, stage: :report)
      )
    end

    complete = fn ->
      Engine.broadcast(percent_progress(label: label, stage: :complete))
    end

    {report_progress, complete}
  end
end
