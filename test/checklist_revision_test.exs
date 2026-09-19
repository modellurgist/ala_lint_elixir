defmodule ChecklistRevisionTest do
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "ala_lint_revision_#{System.unique_integer([:positive])}")

  # No peer_ok given anywhere: the defaults are under test.
  @layers [
    {:app, [~r/^App\.(Page|Live)/]},
    {:state, [~r/^App\.Features\./], unit: ~r/^(App\.Features\.[^.]+)/},
    {:domain, [~r/^App\.Domain\./]},
    {:paradigms, [~r/^App\.Paradigms\./]}
  ]

  setup_all do
    File.mkdir_p!(Path.join(@dir, "lib"))

    File.write!(Path.join(@dir, "lib/app.ex"), """
    defmodule App.Page do
      def go(x), do: App.Page.Helpers.fmt(App.Features.Wish.run(x))
      def dispatch(x), do: App.Paradigms.Shell.apply_all(x)
      def guarded(x) do
        if x, do: App.Features.Wish.run(x), else: :none
      end
      def routed(x) do
        case App.Features.Wish.run(x) do
          {:ok, v} -> App.Features.Cart.take(v)
          {:error, e} -> {:error, e}
        end
      end
      def chained(x) do
        with {:ok, v} <- App.Features.Wish.check(x), do: App.Features.Cart.take(v)
      end
      def total(items), do: Enum.count(items) * 2 + length(items)
      def dance(x) do
        {r, _} = App.Features.Wish.check(x)
        App.Features.Cart.take(r)
      end
      def held(x) do
        r = App.Features.Wish.run(x)
        assign(x, :r, r)
      end
      def chain(x), do: worker(x)
      def worker(x), do: x * 3
      def assign(s, _k, _v), do: s
      def forward(x), do: Enum.map(x, &App.Features.Wish.run/1)
      def subscribe_here, do: Phoenix.PubSub.subscribe(App.PubSub, "stock")
    end
    defmodule App.Domain.Imports do
      import Enum, only: [map: 2, reduce: 3]
      def go(xs), do: map(xs, & &1)
    end
    defmodule App.Page.Helpers do
      def fmt(x), do: x
    end
    defmodule App.Features.Wish do
      @moduledoc "Some Prose That Reads Like A Sentence Here"
      @behaviour App.Features.Cart
      def message, do: "Saved to your wishlist"
      def run(x), do: x
      def check(x), do: {:ok, x}
      def subscribe_self, do: Phoenix.PubSub.subscribe(App.PubSub, "wishes")
      def subscribe_given(pubsub, topic), do: Phoenix.PubSub.subscribe(pubsub, topic)
    end
    defmodule App.Features.Cart do
      @callback take(term) :: term
      def take(x), do: App.Domain.Money.new(x)
      def total(%App.Domain.Money{amount: a}), do: a
    end
    defmodule App.Features.Ledger do
      def record(%App.Domain.Money{} = m), do: m
    end
    defmodule App.Domain.Money do
      defstruct amount: 0
      def new(x), do: %__MODULE__{amount: App.Domain.Round.up(x)}
    end
    defmodule App.Domain.Round do
      def up(x) when x > 42, do: x
      def up(x), do: x
    end
    defmodule App.Paradigms.Step do
      @callback push(term, term) :: term
    end
    defmodule App.Domain.Filter do
      @behaviour App.Paradigms.Step
      def push(s, x), do: {s, x}
    end
    defmodule App.Paradigms.Shell do
      def apply_all(x), do: x
      def named(x), do: App.Page.go(x)
    end
    """)

    # Enough small files (over 1000 lines in all, averaging under 100) for the size advisory.
    for n <- 1..14 do
      body = Enum.map_join(1..80, "\n", &"  def f#{&1}(x), do: x")

      File.write!(
        Path.join(@dir, "lib/small_#{n}.ex"),
        "defmodule App.Domain.Small#{n} do\n#{body}\nend\n"
      )
    end

    {:ok,
     report: AlaLint.analyze(Path.join(@dir, "lib"), layers: @layers),
     strict: AlaLint.analyze(Path.join(@dir, "lib"), layers: @layers, strict: true)}
  end

  defp findings(r, rule), do: Enum.filter(r.findings, &(&1.rule == rule))

  describe "R1 by layer, with default peer_ok" do
    test "a domain → domain call is a peer edge when no peer_ok is declared", %{report: r} do
      assert Enum.any?(findings(r, :r1), &(&1.message =~ "Money.new/1" and &1.message =~ "Round"))
    end

    test "calls inside the application layer are not flagged", %{report: r} do
      refute Enum.any?(findings(r, :r1), &(&1.message =~ "Helpers"))
    end

    test "a page using a paradigm-layer shell drops; a shell naming a page is upward", %{
      report: r
    } do
      refute Enum.any?(findings(r, :r1), &(&1.message =~ "Page.dispatch"))
      assert Enum.any?(findings(r, :r1), &(&1.message =~ "Shell.named/1" and &1.message =~ "UP"))
    end
  end

  describe "R10 no longer treats a lower-layer struct as a peer entity" do
    test "a domain struct read by two features is not an R10 error", %{report: r} do
      assert findings(r, :r10) == []
    end

    test "it is the advisory aggregate case under --strict", %{strict: r} do
      assert Enum.any?(findings(r, :r10_aggregate), &(&1.message =~ "Money"))
    end
  end

  describe "R9 owned interfaces" do
    test "a behaviour defined by one feature and implemented by a peer feature", %{report: r} do
      assert Enum.any?(findings(r, :r9), &(&1.message =~ "Wish" and &1.message =~ "peer"))
    end

    test "a paradigm-layer behaviour implemented by a domain module is a port", %{report: r} do
      refute Enum.any?(findings(r, :r9), &(&1.message =~ "Step"))
    end
  end

  describe "self-subscription" do
    test "a feature subscribing to a topic it fixes is flagged", %{report: r} do
      assert Enum.any?(findings(r, :subscribe), &(&1.module == "App.Features.Wish"))
      assert length(findings(r, :subscribe)) == 1
    end

    test "the application subscribing, or a topic passed in, is not", %{report: r} do
      refute Enum.any?(findings(r, :subscribe), &(&1.module == "App.Page"))
    end
  end

  describe "R11 kinds" do
    test "a nil guard is reported as a guard", %{report: r} do
      assert Enum.any?(findings(r, :r11), &(&1.message =~ "guarded/1" and &1.message =~ "guard"))
    end

    test "`with` and an ok/error routing case are not branches", %{report: r} do
      refute Enum.any?(findings(r, :r11), &(&1.message =~ "chained/1"))
      refute Enum.any?(findings(r, :r11), &(&1.message =~ "routed/1"))
    end

    test "a `&Mod.fun/arity` capture is not arithmetic", %{report: r} do
      refute Enum.any?(findings(r, :r11), &(&1.message =~ "forward/1"))
    end

    test "arithmetic in the application is reported", %{report: r} do
      assert Enum.any?(
               findings(r, :r11),
               &(&1.message =~ "total/1" and &1.message =~ "arithmetic")
             )
    end
  end

  test "arities in an import's `only:` are not application literals", %{report: r} do
    refute Enum.any?(findings(r, :r3), &(&1.module == "App.Domain.Imports"))
    refute Enum.any?(r.findings, &(&1.rule == :r3 and &1.message =~ "literal 3 "))
  end

  describe "R11 handling data and working chains" do
    test "binding a feature's result and passing it to another feature is reported", %{report: r} do
      assert Enum.any?(
               findings(r, :r11),
               &(&1.message =~ "dance/1" and &1.message =~ "binds `r`")
             )
    end

    test "binding a result and only storing it is not", %{report: r} do
      refute Enum.any?(findings(r, :r11), &(&1.message =~ "held/1"))
    end

    test "an app function calling an app function that computes is a working chain", %{report: r} do
      assert Enum.any?(findings(r, :r11), &(&1.message =~ "chain/1" and &1.message =~ "worker/1"))
    end
  end

  describe "R3 additions" do
    test "a number in a guard is a literal", %{report: r} do
      assert Enum.any?(
               findings(r, :r3),
               &(&1.module == "App.Domain.Round" and &1.message =~ "42")
             )
    end

    test "message text in a feature is reported; a moduledoc is not", %{report: r} do
      assert Enum.any?(findings(r, :r3), &(&1.message =~ "Saved to your wishlist"))
      refute Enum.any?(findings(r, :r3), &(&1.message =~ "Some Prose"))
    end
  end

  test "abstractions averaging under 100 lines are reported", %{report: r} do
    assert Enum.any?(findings(r, :module_avg), &(&1.message =~ "average"))
  end
end
