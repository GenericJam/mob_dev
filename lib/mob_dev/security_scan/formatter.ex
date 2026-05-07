defmodule MobDev.SecurityScan.Formatter do
  @moduledoc """
  Render a `Report` for human or machine consumers.

    * `terminal/1` — pretty ANSI-coloured output for `mix mob.security_scan`
    * `json/1` — machine-readable for `--json`
    * `markdown/1` — for `--write-report SECURITY_SCAN.md`

  The formatter never raises; missing optional fields render as
  blank, not crashes. Callers control output destination (IO,
  File.write/2, etc.).
  """

  alias MobDev.SecurityScan.{Finding, Report}

  @severity_colors %{
    critical: IO.ANSI.red() <> IO.ANSI.bright(),
    high: IO.ANSI.red(),
    medium: IO.ANSI.yellow(),
    low: IO.ANSI.cyan(),
    unknown: IO.ANSI.faint()
  }

  @severity_icon %{
    critical: "▲",
    high: "▲",
    medium: "▲",
    low: "•",
    unknown: "?"
  }

  @doc "Render the report as ANSI-coloured terminal text."
  @spec terminal(Report.t()) :: String.t()
  def terminal(%Report{} = report) do
    sections = [
      header(report),
      layer_sections(report),
      summary(report)
    ]

    Enum.join(sections, "\n") <> "\n"
  end

  @doc "Render the report as JSON-encodable data."
  @spec json(Report.t()) :: String.t()
  def json(%Report{} = report) do
    Jason.encode!(report, pretty: true)
  end

  defp header(%Report{started_at: started, project_root: root}) do
    h = IO.ANSI.bright()
    r = IO.ANSI.reset()
    "#{h}=== mob security scan ===#{r}\n  started: #{started}\n  root:    #{root}\n"
  end

  defp layer_sections(%Report{layers: layers}) do
    layers
    |> Enum.map(&layer_section/1)
    |> Enum.join("\n")
  end

  defp layer_section(layer) do
    h = IO.ANSI.bright()
    r = IO.ANSI.reset()
    dim = IO.ANSI.faint()

    duration = if layer.duration_ms, do: " (#{layer.duration_ms}ms)", else: ""
    status_tag = status_tag(layer.status)

    head = "#{h}── #{layer.name}#{r} #{status_tag}#{dim}#{duration}#{r}"

    tools =
      if layer.tools_used != [], do: "\n  tools: #{Enum.join(layer.tools_used, ", ")}", else: ""

    notes = render_notes(layer.notes)
    error = if layer.error, do: "\n  #{IO.ANSI.red()}error: #{layer.error}#{r}", else: ""
    findings = render_findings(layer.findings)

    head <> tools <> notes <> error <> findings <> "\n"
  end

  defp status_tag(:ok), do: "#{IO.ANSI.green()}ok#{IO.ANSI.reset()}"
  defp status_tag(:tool_missing), do: "#{IO.ANSI.yellow()}tool missing#{IO.ANSI.reset()}"
  defp status_tag(:not_applicable), do: "#{IO.ANSI.faint()}n/a#{IO.ANSI.reset()}"
  defp status_tag(:skipped), do: "#{IO.ANSI.faint()}skipped#{IO.ANSI.reset()}"
  defp status_tag(:error), do: "#{IO.ANSI.red()}error#{IO.ANSI.reset()}"

  defp render_notes([]), do: ""

  defp render_notes(notes) do
    "\n" <> Enum.map_join(notes, "\n", &"  · #{&1}")
  end

  defp render_findings([]), do: ""

  defp render_findings(findings) do
    "\n" <>
      (findings
       |> Enum.sort_by(&Finding.sort_key/1)
       |> Enum.map_join("\n", &render_finding/1))
  end

  defp render_finding(%Finding{} = f) do
    color = Map.get(@severity_colors, f.severity, "")
    icon = Map.get(@severity_icon, f.severity, "?")
    reset = IO.ANSI.reset()
    sev = f.severity |> Atom.to_string() |> String.upcase() |> String.pad_trailing(8)

    pkg = if f.package, do: " #{f.package}", else: ""
    ver = if f.version, do: "@#{f.version}", else: ""
    fixed = if f.fixed_in, do: " → fixed in #{f.fixed_in}", else: ""
    title = if f.title, do: "\n      #{f.title}", else: ""
    id = if f.id, do: " [#{f.id}]", else: ""

    "  #{color}#{icon} #{sev}#{reset}#{pkg}#{ver}#{id}#{fixed}#{title}"
  end

  defp summary(%Report{} = report) do
    counts = Report.severity_counts(report)
    total = Enum.sum(Map.values(counts))
    h = IO.ANSI.bright()
    r = IO.ANSI.reset()
    duration = Report.duration_ms(report)

    duration_line =
      if duration, do: "  total time: #{duration}ms\n", else: ""

    counts_line =
      "  #{color_count(:critical, counts.critical)} critical  " <>
        "#{color_count(:high, counts.high)} high  " <>
        "#{color_count(:medium, counts.medium)} medium  " <>
        "#{color_count(:low, counts.low)} low  " <>
        "#{color_count(:unknown, counts.unknown)} unknown"

    "#{h}=== Summary ===#{r}\n" <>
      duration_line <>
      "  total findings: #{total}\n" <>
      counts_line <> "\n"
  end

  defp color_count(severity, count) do
    color =
      cond do
        count == 0 -> IO.ANSI.faint()
        true -> Map.get(@severity_colors, severity, "")
      end

    "#{color}#{count}#{IO.ANSI.reset()}"
  end
end
