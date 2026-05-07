defmodule MobDev.SecurityScan.Report do
  @moduledoc """
  Aggregate result of a security scan: every layer's `LayerResult`
  plus run metadata. The report is the single object handed to
  formatters (terminal, JSON, markdown) and the value returned
  from `MobDev.SecurityScan.run/1`.

  Severity rollup helpers (`severity_counts/1`, `worst_severity/1`)
  are colocated here so formatters and the `--strict` exit-code
  logic agree on the math.
  """

  alias MobDev.SecurityScan.{Finding, LayerResult}

  @type t :: %__MODULE__{
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          project_root: String.t(),
          layers: [LayerResult.t()]
        }

  @derive Jason.Encoder
  defstruct started_at: nil,
            finished_at: nil,
            project_root: nil,
            layers: []

  @doc "Flatten findings across all layers."
  @spec all_findings(t()) :: [Finding.t()]
  def all_findings(%__MODULE__{layers: layers}) do
    Enum.flat_map(layers, & &1.findings)
  end

  @doc """
  Count findings by severity across the report.
  Returns a map keyed by `:critical`, `:high`, `:medium`, `:low`,
  `:unknown` — every key is present (zero if no findings at that level).
  """
  @spec severity_counts(t()) :: %{Finding.severity() => non_neg_integer()}
  def severity_counts(%__MODULE__{} = report) do
    base = %{critical: 0, high: 0, medium: 0, low: 0, unknown: 0}

    report
    |> all_findings()
    |> Enum.reduce(base, fn %Finding{severity: sev}, acc ->
      Map.update(acc, sev, 1, &(&1 + 1))
    end)
  end

  @doc """
  Worst severity present in the report. Returns `:none` when the
  report has zero findings.
  """
  @spec worst_severity(t()) :: Finding.severity() | :none
  def worst_severity(%__MODULE__{} = report) do
    counts = severity_counts(report)

    cond do
      counts.critical > 0 -> :critical
      counts.high > 0 -> :high
      counts.medium > 0 -> :medium
      counts.low > 0 -> :low
      counts.unknown > 0 -> :unknown
      true -> :none
    end
  end

  @doc "Total wall-clock duration of the scan in milliseconds, or nil if not yet finished."
  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{finished_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: s, finished_at: f}) do
    DateTime.diff(f, s, :millisecond)
  end
end
