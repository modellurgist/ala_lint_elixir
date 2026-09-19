defmodule Mix.Tasks.Ala.Lint.Encoding do
  @shortdoc "Lint a tree of encoded .ala.md files against the ALA Checklist"

  @moduledoc """
  The counterpart to `mix ala.lint`: instead of a **code** directory, this takes
  a directory of **encoded** files (the `.ala.md` notation `mix ala.encode`
  produces, after a human has completed and verified it) and reports the checklist
  violations the notation carries.

      mix ala.lint.encoding                 # lint ala_encoding/
      mix ala.lint.encoding path/to/enc     # a different encoding tree

  It checks R1 (every edge must drop — upward and cross-peer edges are flagged),
  R4 (`$` hidden state) and R5 (`q` silent contracts), and lists what is still
  unresolved (`[?]` tags, "verify" edges). R3/R6/R7 are not expressible in the
  encoding, so they are not scored here — lint the source with `mix ala.lint`
  for those.
  """
  use Mix.Task

  @usage """
  mix ala.lint.encoding [PATH] [options]

  Lint a tree of encoded `.ala.md` files (default: ala_encoding) — checks the
  checklist marks the notation carries (R1 edge altitude, R4 $, R5 q) and lists
  what is still unresolved. R3/R6/R7 are not encodable and are not scored here.

  Options:
    --limit N    show up to N findings (default 60)
    --help, -h   show this help
  """

  @impl true
  def run(argv) do
    unless AlaLint.CLI.help?(argv, @usage), do: run_lint(argv)
  end

  defp run_lint(argv) do
    {opts, paths, invalid} = OptionParser.parse(argv, strict: [limit: :integer], aliases: [l: :limit])
    AlaLint.CLI.warn_unknown(invalid)
    path = List.first(paths) || "ala_encoding"

    report = AlaLint.EncodingLinter.lint(path)
    Mix.shell().info(AlaLint.EncodingLinter.to_text(report, limit: opts[:limit] || 60))
  end
end
