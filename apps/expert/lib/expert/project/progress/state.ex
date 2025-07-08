defmodule Expert.Project.Progress.State do
  alias Expert.Configuration
  alias Expert.Project.Progress.Percentage
  alias Expert.Project.Progress.Value
  alias Expert.Protocol.Id
  alias Forge.Project
  alias GenLSP.Requests
  alias GenLSP.Structures

  import Forge.EngineApi.Messages

  defstruct project: nil, progress_by_label: %{}

  def new(%Project{} = project) do
    %__MODULE__{project: project}
  end

  def begin(%__MODULE__{} = state, project_progress(label: label)) do
    progress = Value.begin(label)
    progress_by_label = Map.put(state.progress_by_label, label, progress)

    write_work_done(Expert.get_lsp(), progress.token)
    write(Expert.get_lsp(), progress)

    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  def begin(%__MODULE__{} = state, percent_progress(label: label, max: max)) do
    progress = Percentage.begin(label, max)
    progress_by_label = Map.put(state.progress_by_label, label, progress)
    write_work_done(Expert.get_lsp(), progress.token)
    write(Expert.get_lsp(), progress)

    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  def report(%__MODULE__{} = state, project_progress(label: label, message: message)) do
    {progress, progress_by_label} =
      Map.get_and_update(state.progress_by_label, label, fn old_value ->
        new_value = Value.report(old_value, message)
        {new_value, new_value}
      end)

    write(Expert.get_lsp(), progress)
    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  def report(
        %__MODULE__{} = state,
        percent_progress(label: label, message: message, delta: delta)
      ) do
    {progress, progress_by_label} =
      Map.get_and_update(state.progress_by_label, label, fn old_percentage ->
        new_percentage = Percentage.report(old_percentage, delta, message)
        {new_percentage, new_percentage}
      end)

    write(Expert.get_lsp(), progress)
    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  def complete(%__MODULE__{} = state, project_progress(label: label, message: message)) do
    {progress, progress_by_label} =
      Map.get_and_update(state.progress_by_label, label, fn _ -> :pop end)

    case progress do
      %Value{} = progress ->
        write(Expert.get_lsp(), Value.complete(progress, message))

      _ ->
        :ok
    end

    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  def complete(%__MODULE__{} = state, percent_progress(label: label, message: message)) do
    {progress, progress_by_label} =
      Map.get_and_update(state.progress_by_label, label, fn _ -> :pop end)

    case progress do
      %Percentage{} = progress ->
        write(Expert.get_lsp(), Percentage.complete(progress, message))

      nil ->
        :ok
    end

    %__MODULE__{state | progress_by_label: progress_by_label}
  end

  defp write_work_done(lsp, token) do
    if Configuration.client_supports?(:work_done_progress) do
      GenLSP.request(lsp, %Requests.WindowWorkDoneProgressCreate{
        id: Id.next(),
        params: %Structures.WorkDoneProgressCreateParams{token: token}
      })
    end
  end

  defp write(lsp, %progress_module{token: token} = progress) when not is_nil(token) do
    if Configuration.client_supports?(:work_done_progress) do
      GenLSP.notify(
        lsp,
        progress_module.to_protocol(progress)
      )
    end
  end

  defp write(_, _), do: :ok
end
