defmodule ChecklistRevisionTest do
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "ala_lint_revision_#{System.unique_integer([:positive])}")

  # No peer_ok given anywhere: the defaults are under test.
  @layers [
    {:app, [~r/^App\.(Page|Live)/]},
    {:feature, [~r/^App\.Features\./], unit: ~r/^(App\.Features\.[^.]+)/},
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
      def subscribe_here, do: Phoenix.PubSub.subscribe(App.PubSub, "stock")
    end
    defmodule App.Page.Helpers do
      def fmt(x), do: x
    end
    defmodule App.Features.Wish do
      @behaviour App.Features.Cart
      def run(x), do: x
      def check(x), do: {:ok, x}
      def subscribe_self, do: Phoenix.PubSub.subscribe(App.PubSub, "wishes")
      def subscribe_given(pubsub, topic), do: Phoenix.PubSub.subscribe(pubsub, topic)
    end
    defmodule App.Features.Cart do
      @callback take(term) :: term
      def take(x), do: App.Domain.Money.new(x)
    end
    defmodule App.Features.Ledger do
      def record(%App.Domain.Money{} = m), do: m
    end
    defmodule App.Domain.Money do
      defstruct amount: 0
      def new(x), do: %__MODULE__{amount: App.Domain.Round.up(x)}
    end
    defmodule App.Domain.Round do
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

    # A few small single-module files, so the average-size check has files to average.
    for n <- 1..5 do
      File.write!(Path.join(@dir, "lib/small_#{n}.ex"), """
      defmodule App.Domain.Small#{n} do
        def id(x), do: x
      end
      """)
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

    test "arithmetic in the application is reported", %{report: r} do
      assert Enum.any?(
               findings(r, :r11),
               &(&1.message =~ "total/1" and &1.message =~ "arithmetic")
             )
    end
  end

  test "abstractions averaging under 100 lines are reported", %{report: r} do
    assert Enum.any?(findings(r, :module_size), &(&1.message =~ "average"))
  end
end
