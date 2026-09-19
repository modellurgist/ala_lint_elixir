defmodule Mix.Tasks.Ala.Encode do
  @shortdoc "Auto-encode a codebase into the ALA Checklist notation (a human-completed draft)"

  @moduledoc """
  Generate a **parallel directory** encoding every function of `<path>` (default
  `lib`) in the ALA Checklist notation — module `[tag]`s, functions, project
  edges (annotated drop/peer/up when a layer map is supplied), `$` hidden-state
  flags, and `q` shared-literal flags.

      mix ala.encode                       # encode lib/ → ala_encoding/
      mix ala.encode lib/my_app --out enc  # custom source + output dir
      mix ala.encode --layers-module MyApp.AlaLayers   # tagged output

  The output is a **draft**: the tool cannot make the `[tag]` judgement or decide
  the `$`/`q` flags, and it cannot infer data wires (`p`/`*p`) at all. Every file
  starts with a checklist of what a human must complete and verify. See
  `ala-checklist.md`.

  For **tagged** output, supply a layer map. Either declare one project-wide —
  `config :ala_lint, layers_module: MyApp.AlaLayers` (a module exporting
  `layers/0`) — and it is picked up automatically, or name it per-run with
  `--layers-module`. Without a layer map every `[tag]` is `[?]`.
  """
  use Mix.Task

  @usage """
  mix ala.encode [PATH] [options]

  Write a parallel `.ala.md` tree encoding every function of PATH (default: lib)
  in the ALA Checklist notation — a draft a human completes/verifies.

  Options:
    --out DIR            output directory (default: ala_encoding)
    --layers-module MOD  a module exporting layers/0 → filled-in [tag]s (else [?])
    --help, -h           show this help
  """

  @impl true
  def run(argv) do
    unless AlaLint.CLI.help?(argv, @usage), do: run_encode(argv)
  end

  defp run_encode(argv) do
    {opts, paths, invalid} =
      OptionParser.parse(argv, strict: [out: :string, layers_module: :string])

    AlaLint.CLI.warn_unknown(invalid)
    path = List.first(paths) || "lib"
    out = opts[:out] || "ala_encoding"

    layers = AlaLint.Layers.load(layers_module: opts[:layers_module])
    files = AlaLint.encode(path, layers: layers)

    Enum.each(files, fn {rel, content} ->
      dest = Path.join(out, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end)

    Mix.shell().info(
      "wrote #{length(files)} encoding files to #{out}/ (a draft — complete the tags/edges/$/q by hand)"
    )
  end
end
