defmodule AlaLint.Acceptance do
  @moduledoc """
  A reviewer's decision written in the code. `# ala:accept r3` accepts the next line for the named
  check (several: `r3,r5`; more lines: `lines=3`; a reason after `--`); in HEEx, `<%!-- ala:accept r11 --%>`.
  The linter can't tell an application literal from a domain's own word, or routing from logic; the
  person reading the finding can, and this records the call where the code is.
  """

  @pattern ~r/ala:accept\s+([a-z0-9_]+(?:,[a-z0-9_]+)*)(?:\s+lines=(\d+))?(?:\s+--\s*(.*?))?\s*(?:--%>)?\s*$/
  @marker ~r/(#|<%!--)\s*ala:accept\b/

  @type t :: %{file: String.t(), line: pos_integer(), checks: [atom()], from: pos_integer(), to: pos_integer(), reason: String.t()}

  @doc "Every acceptance comment in the files under the roots (`.ex`, `.exs` and `.heex`)."
  def scan_roots(roots) do
    roots
    |> List.wrap()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs,heex}")))
    |> Enum.uniq()
    |> Enum.flat_map(&scan_file/1)
  end

  def scan_file(file) do
    case File.read(file) do
      {:ok, src} -> scan(src, file)
      _ -> []
    end
  end

  def scan(src, file) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      # Regex.run drops trailing groups that didn't match, so pad to the four we read
      with true <- Regex.match?(@marker, text),
           [_, checks, count, reason] <- pad(Regex.run(@pattern, text)) do
        checks = checks |> String.split(",") |> Enum.map(&String.to_atom/1)
        unknown = Enum.reject(checks, &(&1 in known_checks()))

        if unknown != [] do
          raise ArgumentError,
                "#{file}:#{line}: ala:accept names no such check: #{Enum.join(unknown, ", ")} (see mix ala.lint --list-checks)"
        end

        n = if count == "", do: 1, else: String.to_integer(count)
        [%{file: file, line: line, checks: checks, from: line + 1, to: line + n, reason: String.trim(reason)}]
      else
        _ -> []
      end
    end)
  end

  defp pad(nil), do: nil
  defp pad(groups), do: groups ++ List.duplicate("", 4 - length(groups))

  @doc "Whether this acceptance takes the finding out of the score."
  def covers?(a, finding),
    do: finding.file == a.file and finding.rule in a.checks and finding.line >= a.from and finding.line <= a.to

  def range(%{from: f, to: f}), do: Integer.to_string(f)
  def range(%{from: f, to: t}), do: "#{f}–#{t}"

  # the names `mix ala.lint --list-checks` prints
  def known_checks do
    Regex.scan(~r/^  ([a-z0-9_]+)\s/m, AlaLint.CLI.checks_listing())
    |> Enum.map(fn [_, name] -> String.to_atom(name) end)
    |> Enum.uniq()
  end
end
