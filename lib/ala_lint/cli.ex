defmodule AlaLint.CLI do
  @moduledoc false
  # Shared argument handling for the `mix ala.*` tasks: an actual `--help`/`-h`
  # flag, and a warning (rather than silence) for unrecognised options.

  @doc "If argv asks for help, print `usage` and return true (the caller then stops)."
  def help?(argv, usage) do
    if "--help" in argv or "-h" in argv do
      Mix.shell().info(usage)
      true
    else
      false
    end
  end

  @checks_listing """
  ALA checks and how each is scored. Change any of this in a `.ala_lint.exs` map
  (`checks: %{r7: :scored, height: [max: 4], r11: :off}`) or per run with the
  flags shown.

  REQUIRED  (scored by default; a violation fails --min-score)
    r1    every edge drops (down-only)
    r2    no shared mutable state between peers
    r3    application literals live at the composition
    r4    state is threaded, not hidden
    r5    no silent contracts
    r6    every abstraction names a learnable concept
    r10   no shared entity (feature-tier)
    layer layer-validity (coverage + tags), with a layer map

  ADVISORY  (reported by default; scored under --strict; --enforce CHECK to promote one)
    r7             unearned / dead abstraction
    module_size    module over N lines          --set module_size.max=N     (default 500)
    height         hops between abstractions     --set height.max=N          (default 5)
    passthrough    public cross-module rename
    r1_ref         reference-level R1 (templates, aliases)

  ASPIRATIONAL  (reported by default; scored only under --super-strict)
    r11            no logic at the top           --set app_share.max=F       (default 0.20)
    public_surface wide public API (encapsulation) --set public_surface.max=N (default 12)
    r10_aggregate  shared domain aggregate

  NOT MACHINE-SCORED  (a human reads for these)
    r8    reads as the requirements
    r9    ports paradigm-typed (partial, via r1 + r1_ref)

  Turn any check off with --disable CHECK, or `checks: %{CHECK: :off}` in the file.
  """

  @doc "Human-readable listing of every check, its tier, and its threshold flag."
  def checks_listing, do: @checks_listing

  @doc "Warn on stderr about the unrecognised options OptionParser collected."
  def warn_unknown([]), do: :ok

  def warn_unknown(invalid) do
    names = invalid |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")
    Mix.shell().error("ala_lint: ignoring unknown option(s): #{names} — see --help")
  end
end
