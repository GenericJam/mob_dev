defmodule MobDev.SecurityScan.Runner do
  @moduledoc """
  Orchestrates the scan: invokes each enabled layer in turn,
  collects `LayerResult`s, and returns a `Report`.

  Layers are run sequentially (not concurrently) so that terminal
  output stays readable in the streaming formatter and so that
  resource-heavy scanners like semgrep don't dogpile a laptop.

  Layers never raise — failures land as `%LayerResult{status: :error}`.
  The runner additionally guards every callback with a `try`, so a
  bug in one layer can't take the whole scan down.
  """

  alias MobDev.SecurityScan.{LayerResult, Report}

  @doc """
  Runs the listed layers in order. `opts` is forwarded to each
  layer's `run/1` callback. The optional `:on_layer_start` and
  `:on_layer_done` callbacks let the formatter stream progress
  to the terminal as layers complete.
  """
  @spec run([module()], keyword()) :: Report.t()
  def run(layers, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    skip = Keyword.get(opts, :skip, [])
    on_start = Keyword.get(opts, :on_layer_start, fn _ -> :ok end)
    on_done = Keyword.get(opts, :on_layer_done, fn _ -> :ok end)

    started_at = DateTime.utc_now()

    layer_results =
      Enum.map(layers, fn layer ->
        on_start.(layer.name())
        result = run_layer(layer, skip, opts)
        on_done.(result)
        result
      end)

    %Report{
      started_at: started_at,
      finished_at: DateTime.utc_now(),
      project_root: project_root,
      layers: layer_results
    }
  end

  defp run_layer(layer, skip, opts) do
    name = layer.name()

    if name in skip do
      %LayerResult{
        name: name,
        status: :skipped,
        notes: ["skipped via --skip flag"]
      }
    else
      execute(layer, opts)
    end
  end

  defp execute(layer, opts) do
    started = System.monotonic_time(:millisecond)

    try do
      %LayerResult{} = result = layer.run(opts)
      duration = System.monotonic_time(:millisecond) - started
      %{result | duration_ms: duration}
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - started

        %LayerResult{
          name: layer.name(),
          status: :error,
          error: Exception.message(e),
          duration_ms: duration
        }
    end
  end
end
