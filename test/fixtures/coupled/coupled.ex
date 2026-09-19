# A deliberately bad fixture that trips several rules (used by the tests).
defmodule Fixtures.Coupled.A do
  def go(x), do: Fixtures.Coupled.B.help(x) + 1   # A ↔ B cycle (R1)
  def topic, do: "orders:updated"                  # duplicated string (R5)
  def stash(v), do: Process.put(:acc, v)           # process dictionary (R4)
  defp x(a), do: a                                 # meaningless name + trivial single-use (R6/R7)
  def use_x(a), do: x(a)
end

defmodule Fixtures.Coupled.B do
  def help(v), do: Fixtures.Coupled.A.topic() <> to_string(v)  # B ↔ A cycle (R1)
  def topic, do: "orders:updated"                  # same literal in a 2nd module (R5)
  def rate, do: 8.3                                 # magic literal (R3)
  defp dead(z), do: z * 2                           # never called → dead code (R7)
end
