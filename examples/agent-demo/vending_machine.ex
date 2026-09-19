defmodule VendingMachine.Change do
  @moduledoc """
  Domain layer: pure change-making over a coin float. Knows nothing about
  products, prices, or vending machines — just coins and totals.
  """

  @denominations [25, 10, 5]

  def add_coin(float, coin) when coin in @denominations do
    Map.update(float, coin, 1, &(&1 + 1))
  end

  def make_change(float, amount), do: greedy(float, amount, @denominations, [])

  defp greedy(float, 0, _denoms, coins), do: {:ok, Enum.reverse(coins), float}
  defp greedy(_float, amount, [], _coins) when amount > 0, do: :error

  defp greedy(float, amount, [d | rest], coins) do
    available = Map.get(float, d, 0)
    usable = min(available, div(amount, d))
    new_float = if usable > 0, do: Map.update!(float, d, &(&1 - usable)), else: float
    greedy(new_float, amount - usable * d, rest, List.duplicate(d, usable) ++ coins)
  end
end

defmodule VendingMachine.Session do
  @moduledoc """
  Feature layer: one vending transaction. State (credit, stock, float,
  products) is threaded through every call and returned, never hidden.
  Results are returned as tagged data, not printed or thrown.
  """

  defstruct credit: 0, products: %{}, stock: %{}, float: %{}

  alias VendingMachine.Change

  def new(products, stock, float) do
    %__MODULE__{products: products, stock: stock, float: float}
  end

  def insert_coin(session, coin) when coin in [5, 10, 25] do
    %{session | credit: session.credit + coin, float: Change.add_coin(session.float, coin)}
  end

  def select_product(session, code) do
    case Map.fetch(session.products, code) do
      :error -> {session, {:unknown_code, code}}
      {:ok, {name, price}} -> select_known_product(session, code, name, price)
    end
  end

  defp select_known_product(session, code, name, price) do
    cond do
      Map.get(session.stock, code, 0) <= 0 -> {session, {:out_of_stock, name}}
      session.credit < price -> {session, {:insufficient_funds, price - session.credit}}
      true -> dispense(session, code, name, price)
    end
  end

  defp dispense(session, code, name, price) do
    change_due = session.credit - price

    case Change.make_change(session.float, change_due) do
      {:ok, coins, new_float} ->
        new_session = %{
          session
          | credit: 0,
            float: new_float,
            stock: Map.update!(session.stock, code, &(&1 - 1))
        }

        {new_session, {:dispensed, name, coins}}

      :error ->
        {session, {:change_unavailable, name}}
    end
  end

  def cancel(session) do
    case Change.make_change(session.float, session.credit) do
      {:ok, coins, new_float} -> {%{session | credit: 0, float: new_float}, {:refunded, coins}}
      :error -> {session, {:refund_unavailable}}
    end
  end
end

defmodule VendingMachine do
  @moduledoc """
  Application layer: composition and configuration only. Reading this
  module tells you what the machine sells, what it starts stocked with,
  and what a session of use looks like.

      iex> VendingMachine.run()

  Demonstrates a successful purchase with change, then a decline for
  insufficient funds followed by a cancel/refund.
  """

  @products %{
    "A1" => {"Chips", 45},
    "A2" => {"Soda", 65},
    "B1" => {"Candy", 30}
  }

  @initial_stock %{"A1" => 3, "A2" => 0, "B1" => 5}

  @initial_float %{25 => 10, 10 => 10, 5 => 10}

  alias VendingMachine.Session

  def run do
    session = Session.new(@products, @initial_stock, @initial_float)

    IO.puts("-- buying B1 (Candy, 30c) with two coins that overpay --")
    session = session |> Session.insert_coin(25) |> Session.insert_coin(10)
    {session, result} = Session.select_product(session, "B1")
    IO.puts(describe(result))

    IO.puts("-- trying A2 (Soda, 65c) with only 25c inserted --")
    session = Session.insert_coin(session, 25)
    {session, result} = Session.select_product(session, "A2")
    IO.puts(describe(result))

    IO.puts("-- canceling for a refund --")
    {_session, result} = Session.cancel(session)
    IO.puts(describe(result))
  end

  defp describe({:dispensed, name, coins}), do: "dispensed #{name}, change: #{inspect(coins)}"
  defp describe({:insufficient_funds, more}), do: "need #{more}c more"
  defp describe({:out_of_stock, name}), do: "#{name} is out of stock, money held"
  defp describe({:unknown_code, code}), do: "no product #{code}, money held"
  defp describe({:change_unavailable, name}), do: "#{name} selected but machine can't make change"
  defp describe({:refunded, coins}), do: "refunded: #{inspect(coins)}"
  defp describe({:refund_unavailable}), do: "refund unavailable, money held"
end

VendingMachine.run()
