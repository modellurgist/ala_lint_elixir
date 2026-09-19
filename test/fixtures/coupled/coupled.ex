# A deliberately bad fixture that trips several rules (used by the tests).
defmodule Fixtures.Coupled.A do
  # A ↔ B cycle (R1)
  def go(x), do: Fixtures.Coupled.B.help(x) + 1
  # duplicated string (R5)
  def topic, do: "orders:updated"
  # process dictionary (R4)
  def stash(v), do: Process.put(:acc, v)
  # meaningless name + trivial single-use (R6/R7)
  defp x(a), do: a
  def use_x(a), do: x(a)
end

defmodule Fixtures.Coupled.B do
  # B ↔ A cycle (R1)
  def help(v), do: Fixtures.Coupled.A.topic() <> to_string(v)
  # same literal in a 2nd module (R5)
  def topic, do: "orders:updated"
  # magic literal (R3)
  def rate, do: 8.3
  # never called → dead code (R7)
  defp dead(z), do: z * 2
end
