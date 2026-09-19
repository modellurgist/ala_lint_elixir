defmodule AlaLint.Finding do
  @moduledoc "One rule violation, with its location and severity weight."

  @enforce_keys [:rule, :message, :module, :file, :line, :weight]
  defstruct [:rule, :message, :module, :file, :line, :weight, severity: :error]

  @type severity :: :error | :warn

  @type t :: %__MODULE__{
          rule: atom(),
          message: String.t(),
          module: String.t() | nil,
          file: String.t(),
          line: non_neg_integer(),
          weight: pos_integer(),
          severity: severity()
        }
end
