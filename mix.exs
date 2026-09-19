defmodule AlaLint.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/modellurgist/ala_lint"

  def project do
    [
      app: :ala_lint,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "AlaLint",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    # No runtime deps — pure stdlib static analysis. (Add {:ex_doc, …} locally
    # when generating HTML docs for a Hex release.)
    []
  end

  defp description do
    "A static-analysis linter that scores an Elixir codebase against the ALA Checklist " <>
      "(R1–R11): coupling, layering, requirements-locus, state-as-a-wire, contracts, nameability, " <>
      "and abstraction minimality. Reports violations with locations and an overall design score."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md .formatter.exs)
    ]
  end
end
