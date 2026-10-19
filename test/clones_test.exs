defmodule AlaLint.ClonesTest do
  use ExUnit.Case, async: true

  defp analyze(files, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "ala_clones_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for {name, src} <- files, do: File.write!(Path.join(dir, name), src)
    report = AlaLint.analyze(dir, opts)
    File.rm_rf!(dir)
    report
  end

  defp clones(report), do: Enum.filter(report.findings, &(&1.rule == :clone))

  @promo """
  defmodule App.Promo do
    def enter(promo, %{code: code}) do
      case App.Validate.call(promo.codes, code) do
        {:ok, percentage} ->
          code = code |> String.trim() |> String.upcase()
          {%{promo | code: code}, [discount: %{code: code, percentage: percentage}, applied: code]}

        {:error, :invalid_code} ->
          {promo, [rejected: code]}
      end
    end
  end
  """

  test "a copy with renamed variables and other literals, in another module, is one finding" do
    copy = """
    defmodule App.OrderTotals do
      def apply_code(totals, %{code: entered}) do
        case App.Validate.call(totals.codes, entered) do
          {:ok, pct} ->
            entered = entered |> String.trim() |> String.upcase()
            {%{totals | code: entered}, [promo: %{code: entered, percentage: pct}, ok: entered]}

          {:error, :bad} ->
            {totals, [refused: entered]}
        end
      end
    end
    """

    r = analyze([{"promo.ex", @promo}, {"order_totals.ex", copy}])
    assert [f] = clones(r)
    assert f.message =~ "Promo.enter/2"
    assert f.message =~ "OrderTotals.apply_code/2"
    assert f.message =~ "one abstraction"
    assert f.severity == :warn

    refute Enum.any?(r.scored_findings, &(&1.rule == :clone))
    assert r.rules.by_rule.r7.advisory >= 1

    strict = analyze([{"promo.ex", @promo}, {"order_totals.ex", copy}], strict: true)
    assert Enum.any?(strict.scored_findings, &(&1.rule == :clone))
  end

  test "a copy inside one module is clone_inside: reported, never scored by a tier" do
    same = """
    defmodule App.Promo do
      def enter(promo, %{code: code}) do
        case App.Validate.call(promo.codes, code) do
          {:ok, percentage} ->
            code = code |> String.trim() |> String.upcase()
            {%{promo | code: code}, [discount: %{code: code, percentage: percentage}, applied: code]}

          {:error, :invalid_code} ->
            {promo, [rejected: code]}
        end
      end

      def reenter(p, %{code: c}) do
        case App.Validate.call(p.codes, c) do
          {:ok, pct} ->
            c = c |> String.trim() |> String.upcase()
            {%{p | code: c}, [discount: %{code: c, percentage: pct}, applied: c]}

          {:error, :bad} ->
            {p, [rejected: c]}
        end
      end
    end
    """

    r = analyze([{"promo.ex", same}], super_strict: true)
    assert clones(r) == []
    assert [f] = Enum.filter(r.findings, &(&1.rule == :clone_inside))
    assert f.message =~ "Promo.enter/2" and f.message =~ "Promo.reenter/2"
    refute Enum.any?(r.scored_findings, &(&1.rule == :clone_inside))
    assert :clone_inside in AlaLint.Acceptance.known_checks()
  end

  # the pair from the 2026-10-19 change-cost experiment, where an agent copied a promo into totals
  test "a copy that was then edited is found as nearly the same logic" do
    promo = """
    defmodule App.Promo do
      def enter(%__MODULE__{} = promo, %{code: code}) do
        case check(promo.codes, code) do
          {:ok, percentage} ->
            code = code |> String.trim() |> String.upcase()
            {%{promo | code: code}, [discount: %{code: code, percentage: percentage}, applied: code]}

          {:error, :invalid_code} ->
            {promo, [rejected: code]}
        end
      end

      defp check(nil, _code), do: {:error, :invalid_code}
      defp check(codes, code), do: App.ValidatePromo.call(codes, code)
    end
    """

    edited = """
    defmodule App.OrderTotals do
      def enter_promo(%__MODULE__{} = totals, %{code: code}) do
        case App.ValidatePromo.call(totals.pricing.promo, code) do
          {:ok, percentage} ->
            code = code |> String.trim() |> String.upcase()
            {totals, outs} = changed(%{totals | promo: %{code: code, percentage: percentage}})
            {totals, outs ++ [applied: code]}

          {:error, :invalid_code} ->
            {totals, [rejected: code]}
        end
      end

      defp changed(t), do: {t, []}
    end
    """

    assert [f] = clones(analyze([{"promo.ex", promo}, {"order_totals.ex", edited}]))
    assert f.message =~ "nearly the same logic"
    assert f.message =~ "OrderTotals.enter_promo/2"
  end

  test "a run of statements copied into a longer function is found as part of it" do
    original = """
    defmodule App.Shipping do
      def quote(cart, rates) do
        subtotal = Enum.reduce(cart.lines, 0, fn l, acc -> acc + l.price * l.qty end)
        rate = Map.fetch!(rates, cart.method)
        fee = if subtotal >= rate.free_above, do: 0, else: rate.cost + div(subtotal, 100)
        {subtotal, fee}
      end
    end
    """

    longer = """
    defmodule App.Invoice do
      def build(order, rates) do
        header = %{id: order.id, at: DateTime.utc_now()}
        total = Enum.reduce(order.lines, 0, fn line, sum -> sum + line.price * line.qty end)
        rate = Map.fetch!(rates, order.method)
        fee = if total >= rate.free_above, do: 0, else: rate.cost + div(total, 100)
        Map.merge(header, %{total: total + fee, lines: length(order.lines)})
      end
    end
    """

    assert [f] = clones(analyze([{"shipping.ex", original}, {"invoice.ex", longer}]))
    assert f.message =~ "part of App.Invoice.build/2" or f.message =~ "part of Invoice.build/2"
  end

  test "a small shared shape stays below the threshold, and the threshold is configurable" do
    a = """
    defmodule App.A do
      def label(x), do: x |> String.trim() |> String.upcase()
    end
    """

    b = """
    defmodule App.B do
      def tag(y), do: y |> String.trim() |> String.upcase()
    end
    """

    assert clones(analyze([{"a.ex", a}, {"b.ex", b}])) == []
    assert [_] = clones(analyze([{"a.ex", a}, {"b.ex", b}], min_clone_size: 5))

    assert [_] =
             clones(analyze([{"a.ex", a}, {"b.ex", b}], checks: %{clone: [max: 5]}))
  end

  test "the same shape calling different functions is different logic" do
    a = """
    defmodule App.Stock do
      def check(lines, levels) do
        case App.Levels.fetch(levels, lines) do
          {:ok, short} -> {:error, Enum.map(short, &App.Levels.name/1)}
          :none -> {:ok, Enum.sort_by(lines, & &1.position)}
        end
      end
    end
    """

    b = """
    defmodule App.Address do
      def check(form, rules) do
        case App.Rules.validate(rules, form) do
          {:ok, missing} -> {:error, Enum.map(missing, &App.Rules.message/1)}
          :none -> {:ok, Enum.reject(form, & &1.blank)}
        end
      end
    end
    """

    assert clones(analyze([{"stock.ex", a}, {"address.ex", b}])) == []
  end

  test "wiring clauses that look alike are not clones" do
    page = fn name ->
      """
      defmodule App.#{name} do
        def handle_event("apply", %{"code" => code}, s, out),
          do: run(s, :promo, &App.Promo.enter(&1, %{code: code}), out)

        def handle_event("select", %{"method" => m}, s, out),
          do: run(s, :totals, &App.Totals.select(&1, %{method: m}), out)

        def handle_event("go", _params, s, out), do: run(s, :totals, &App.Totals.go(&1, nil), out)

        defp run(s, part, step, out), do: App.Steps.run(s, part, step, &wire(&1, &2, &3, out))

        defp wire(s, :promo, {:discount, d}, out), do: run(s, :totals, &App.Totals.discount(&1, d), out)
        defp wire(s, :totals, {:summary, summary}, out), do: out.(s, {:summary, summary})
        defp wire(s, :totals, {:review, summary}, out), do: out.(s, {:review, summary})
        defp wire(s, :totals, {:started, summary}, out), do: out.(s, {:started, summary})

        def ports,
          do: %{in: [contents: :contents], out: [summary: :summary, review: :summary, started: :summary]}
      end
      """
    end

    assert clones(analyze([{"cart.ex", page.("Cart")}, {"order.ex", page.("Order")}])) == []
  end
end
