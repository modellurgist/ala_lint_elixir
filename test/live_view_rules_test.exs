defmodule AlaLint.LiveViewRulesTest do
  use ExUnit.Case, async: true

  @layers [
    {:app, [~r/^App\.Page/]},
    {:feature, [~r/^App\.Features\./]},
    {:domain, [~r/^App\.Domain\./]},
    {:platform, [~r/^App\.Store/, ~r/^App\.Binder/, ~r/^App\.Parts/]}
  ]

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ala_lint_lv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "page.ex"), ~S'''
    defmodule App.Page do
      alias App.Features.Cart
      alias App.Domain.Rule
      @gift_wrap_unit 299

      def bindings(cart_id), do: %{{:cart, :rows} => [{:via, &add_line(cart_id, &1), []}]}

      def handle_event("start", _, socket), do: Cart.start(socket, socket.assigns.summary)
      def handle_info(_msg, socket), do: socket

      defp add_line(cart_id, p) do
        App.Store.add(cart_id, p)
        App.Store.list(cart_id)
      end

      def render(assigns) do
        ~H"""
        <div :if={@count == 0}>{Money.new(@price * @qty)}</div>
        <div :for={row <- @rows}>{Rule.call(row)}</div>
        <%= case @status do %>
        <% end %>
        <p :if={@flag} class={[@on && "on"]}>{@summary.total} Gift wrap ($2.99)</p>
        <.live_component module={Cart} id="cart" />
        """
      end
    end
    ''')

    File.write!(Path.join(dir, "cart.ex"), ~S'''
    defmodule App.Features.Cart do
      def ports, do: %{in: [start: :event], out: [rows: :row_change, gone: :item]}
      def start(cart, _), do: {cart, [rows: 1, extra: 2]}
      def schema(cs), do: validate_format(cs, :code, ~r/x/, message: "must look like PO-1234")
      def label(rate), do: "free over #{rate}"
      def items(c), do: %{currency: "usd", c: c}
    end
    ''')

    File.write!(Path.join(dir, "domain.ex"), ~S'''
    defmodule App.Domain.Rule do
      defstruct unit: 0
      def new(unit), do: %__MODULE__{unit: unit}
      def call(%__MODULE__{unit: unit}, count), do: count * unit
      def other(%__MODULE__{unit: unit}), do: unit
    end
    ''')

    File.write!(Path.join(dir, "parts.ex"), ~S'''
    defmodule App.Parts do
      use Phoenix.Component
      def row(assigns), do: ~H"""
      <div><button>Save for later</button><input placeholder="Promo code" /></div>
      """
    end
    ''')

    File.write!(Path.join(dir, "binder.ex"), ~S'''
    defmodule App.Binder do
      def apply_binding({:stream, _}, s), do: s
      def apply_binding({:assign, _}, s), do: s
      def apply_binding({:flash, _}, s), do: s
      def apply_binding({:input, _}, s), do: s
      def apply_binding({:via, _}, s), do: s
      def apply_binding(:redirect, s), do: s
    end
    ''')

    File.write!(Path.join(dir, "store.ex"), ~S'''
    defmodule App.Store do
      def add(_c, _p), do: :ok
      def list(_c), do: []
    end
    ''')

    r = AlaLint.analyze(dir, layers: @layers, strict: true)
    {:ok, r: r}
  end

  defp msgs(r, rule), do: for(f <- r.findings, f.rule == rule, do: f.message)
  defp any?(r, rule, pattern), do: Enum.any?(msgs(r, rule), &(&1 =~ pattern))

  test "logic in an application template is R11", %{r: r} do
    assert any?(r, :r11, "compares (`==`)")
    assert any?(r, :r11, "computes (`*`)")
    assert any?(r, :r11, "iterates")
    assert any?(r, :r11, "uses `case`")
    assert any?(r, :r11, "calls Domain.Rule.call")
  end

  test "wiring forms in a template are not logic", %{r: r} do
    refute any?(r, :r11, "@flag")
    refute any?(r, :r11, "@summary.total")
    refute any?(r, :r11, "@on &&")
  end

  test "words and codes below the composition are R3", %{r: r} do
    assert any?(r, :r3, ~s("Save for later"))
    assert any?(r, :r3, ~s("Promo code"))
    assert any?(r, :r3, ~s(validation message "must look like PO-1234"))
    assert any?(r, :r3, "sentence built by interpolation")
    assert any?(r, :r3, ~s(currency code "usd"))
  end

  test "a label restating a configured amount is R5", %{r: r} do
    assert any?(r, :r5, "$2.99")
  end

  test "declared ports: drift both ways, and an unwired output", %{r: r} do
    assert any?(r, :ports, "emits `extra`")
    assert any?(r, :ports, "declares output `gone`")
    assert any?(r, :ports_unwired, "`gone`")
    refute any?(r, :ports_unwired, "`rows`")
  end

  test "an assign handed to a lower call, a wiring closure, and store work in a helper", %{r: r} do
    assert any?(r, :r11, "reads an assign and passes it into Features.Cart.start")
    assert any?(r, :wiring_closure, "add_line")
    assert any?(r, :r11, "page helper doing store work")
  end

  test "report-only measures", %{r: r} do
    assert any?(r, :r11_share, "of application functions")
    assert any?(r, :hops, "one message hop")
    assert any?(r, :vocabulary, "6 kinds")
    refute Enum.any?(r.scored_findings, &(&1.rule in [:r11_share, :hops, :vocabulary, :ports_unwired]))
  end

  test "a configured rule is neither a primitive wrapper nor a shared aggregate", %{r: r} do
    refute any?(r, :r6, "Rule.call")
    refute any?(r, :r10_aggregate, "Rule")
  end
end

defmodule AlaLint.UnassignedTest do
  use ExUnit.Case, async: true

  test "a module matching no layer is a loud, unscored warning" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_unassigned_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.ex"), "defmodule App.Page do\n  def x, do: 1\nend\n")
    File.write!(Path.join(dir, "b.ex"), "defmodule Stray.Thing do\n  def y, do: 2\nend\n")

    r = AlaLint.analyze(dir, layers: [{:app, [~r/^App\./]}, {:domain, [~r/^App\.Domain/]}])

    assert [%{module: "Stray.Thing", severity: :warn}] = Enum.filter(r.findings, &(&1.rule == :unassigned))
    refute Enum.any?(r.scored_findings, &(&1.rule == :unassigned))
    assert AlaLint.Report.to_text(r) =~ "!! WARNING: 1 module(s) (1 functions) match no layer"
    assert AlaLint.Report.unassigned_banner(AlaLint.analyze(dir)) == ""
  end
end
