defmodule AlaLint.Template do
  @moduledoc """
  Reads HEEx markup as text, since the compiler hands `~H` and `.heex` to the
  analyzer as strings. `expressions/1` returns each embedded Elixir expression
  (`{...}`, `attr={...}`, `<%= ... %>`) with its line and attribute name;
  `words/1` returns the text a person reads (text nodes and label-like
  attributes). Comments, `<script>` and `<style>` are skipped.
  """

  @label_attrs ~w(label placeholder title alt aria-label text message prompt)

  @doc "`[{line, attr_or_nil, source}]` for every expression in the markup."
  def expressions(text) do
    {exprs, _plain} = scan(text)
    exprs
  end

  @doc "`[{line, words}]` for text nodes and label-like attribute strings."
  def words(text) do
    {_exprs, plain} = scan(text)

    attrs =
      for [_, _attr, value] <-
            Regex.scan(~r/\s(#{Enum.join(@label_attrs, "|")})="([^"]*)"/, plain),
          readable?(value),
          do: {line_of(text, value), String.trim(value)}

    nodes =
      plain
      |> String.replace(~r/<[^>]*>/s, "\n")
      |> String.replace(~r/&[#\w]+;/, " ")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&readable?/1)
      |> Enum.map(&{line_of(text, &1), &1})

    attrs ++ nodes
  end

  defp readable?(s), do: String.match?(s, ~r/[A-Za-z]{2,}/)

  defp line_of(text, fragment) do
    case :binary.match(text, fragment) do
      {pos, _} -> count_lines(text, pos)
      :nomatch -> 1
    end
  end

  defp count_lines(text, pos),
    do: text |> binary_part(0, pos) |> String.split("\n") |> length()

  # Walks the markup once: collects expressions, and returns the markup with every
  # expression, comment, script and style blanked out (for the word scan).
  defp scan(text), do: scan(text, 0, [], [])

  defp scan(text, i, exprs, plain) when i >= byte_size(text),
    do: {Enum.reverse(exprs), plain |> Enum.reverse() |> IO.iodata_to_binary()}

  defp scan(text, i, exprs, plain) do
    cond do
      at?(text, i, "<%!--") ->
        scan(text, skip_past(text, i, "--%>"), exprs, plain)

      at?(text, i, "<!--") ->
        scan(text, skip_past(text, i, "-->"), exprs, plain)

      at?(text, i, "<script") ->
        scan(text, skip_past(text, i, "</script>"), exprs, plain)

      at?(text, i, "<style") ->
        scan(text, skip_past(text, i, "</style>"), exprs, plain)

      at?(text, i, "<%") ->
        j = skip_past(text, i + 2, "%>")
        body = text |> binary_part(i + 2, max(j - 2 - (i + 2), 0)) |> String.trim_leading("=")
        scan(text, j, [{count_lines(text, i), nil, String.trim(body)} | exprs], [" " | plain])

      :binary.at(text, i) == ?{ ->
        j = close_brace(text, i + 1, 1, false)
        body = binary_part(text, i + 1, max(j - i - 1, 0))
        expr = {count_lines(text, i), attr_before(text, i), String.trim(body)}
        scan(text, j + 1, [expr | exprs], [" " | plain])

      true ->
        scan(text, i + 1, exprs, [binary_part(text, i, 1) | plain])
    end
  end

  defp at?(text, i, s),
    do: byte_size(text) - i >= byte_size(s) and binary_part(text, i, byte_size(s)) == s

  defp skip_past(text, i, s) do
    case :binary.match(text, s, scope: {i, byte_size(text) - i}) do
      {pos, len} -> pos + len
      :nomatch -> byte_size(text)
    end
  end

  # index of the `}` that closes the brace opened before `i`, skipping strings
  defp close_brace(text, i, _depth, _in_string) when i >= byte_size(text), do: byte_size(text)

  defp close_brace(text, i, depth, in_string) do
    case :binary.at(text, i) do
      ?\\ when in_string -> close_brace(text, i + 2, depth, in_string)
      ?" -> close_brace(text, i + 1, depth, not in_string)
      ?{ when not in_string -> close_brace(text, i + 1, depth + 1, in_string)
      ?} when not in_string and depth == 1 -> i
      ?} when not in_string -> close_brace(text, i + 1, depth - 1, in_string)
      _ -> close_brace(text, i + 1, depth, in_string)
    end
  end

  defp attr_before(text, i) do
    from = max(i - 60, 0)

    case Regex.run(~r/([:@\w.-]+)=$/, binary_part(text, from, i - from)) do
      [_, attr] -> attr
      _ -> nil
    end
  end
end
