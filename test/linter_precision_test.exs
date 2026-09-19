defmodule LinterPrecisionTest do
  use ExUnit.Case, async: true

  # The 2026-09-29 precision fixes: each was a finding on a real variant that pointed at
  # something other than a design defect.

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ala_precision_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "web"))
    File.mkdir_p!(Path.join(dir, "components"))

    File.write!(Path.join(dir, "web/page.ex"), """
    defmodule AppWeb.Page do
      @paths %{address: "/cart/checkout"}
      def mount(_p, _s, socket) do
        if connected?(socket), do: App.Foundation.Broadcast.subscribe()
        {:ok, socket}
      end
      def handle_event("a", _, s), do: {:noreply, s}
      def handle_event("b", _, s), do: {:noreply, s}
      def handle_event("c", _, s), do: {:noreply, s}
      def handle_event("d", _, s), do: {:noreply, s}
      def handle_event("e", _, s), do: {:noreply, s}
      def handle_event("f", _, s), do: {:noreply, s}
      def handle_event("g", _, s), do: {:noreply, s}
      def handle_event("h", _, s), do: {:noreply, s}
      def handle_event("i", _, s), do: {:noreply, s}
      def handle_event("j", _, s), do: {:noreply, s}
      def handle_event("k", _, s), do: {:noreply, s}
      def handle_event("l", _, s), do: {:noreply, s}
      def handle_event("m", _, s), do: {:noreply, s}
      def paths, do: @paths
    end
    defmodule AppWeb.Router do
      def routes, do: ["/cart/checkout", "step"]
    end
    defmodule AppWeb.Other do
      def key, do: "step"
    end
    """)

    File.write!(Path.join(dir, "features.ex"), """
    defmodule App.Features.Undo do
      defstruct pending: nil
      def pending?(%__MODULE__{pending: p}), do: p != nil
      def new(_), do: %__MODULE__{}
      def other(a, b), do: a + b
    end
    defmodule App.Domain.GiftWrap do
      def call(count, unit), do: count * unit
    end
    """)

    File.write!(Path.join(dir, "broadcast.ex"), """
    defmodule App.Foundation.Broadcast do
      @topic "stock"
      def subscribe, do: Phoenix.PubSub.subscribe(App.PubSub, @topic)
    end
    """)

    File.write!(Path.join(dir, "components/core_components.ex"), """
    defmodule AppWeb.CoreComponents do
      def hide(ms), do: ms + 200
    end
    """)

    layers = [
      {:app, [~r/^AppWeb\./], app: true, peer_ok: true},
      {:feature, [~r/\.Features\./], unit: ~r/(.*\.Features\.[^.]+)/},
      {:domain, [~r/\.Domain\./], peer_ok: true},
      {:platform, [~r/\.Foundation\./], peer_ok: true}
    ]

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, report: AlaLint.analyze(dir, layers: layers, super_strict: true)}
  end

  defp findings(r, rule), do: Enum.filter(r.findings, &(&1.rule == rule))

  test "public surface counts functions, not clauses", %{report: r} do
    refute Enum.any?(findings(r, :public_surface), &(&1.message =~ "Page"))
  end

  test "a `connected?` guard in mount is routing, not logic at the top", %{report: r} do
    refute Enum.any?(findings(r, :r11), &(&1.message =~ "mount/3 branches"))
  end

  test "a predicate over the module's own state and a single-function module are not primitive wrappers",
       %{report: r} do
    refute Enum.any?(findings(r, :r6), &(&1.message =~ "pending?"))
    refute Enum.any?(findings(r, :r6), &(&1.message =~ "GiftWrap"))
    assert Enum.any?(findings(r, :r6), &(&1.message =~ "Undo.other/2"))
  end

  test "a route string shared with the Router and a four-letter word are not silent contracts", %{
    report: r
  } do
    refute Enum.any?(findings(r, :r5), &(&1.message =~ "/cart/checkout"))
    refute Enum.any?(findings(r, :r5), &(&1.message =~ ~s("step")))
  end

  test "the bottom layer may own its topic", %{report: r} do
    assert findings(r, :subscribe) == []
  end

  test "framework files are not scored", %{report: r} do
    refute Enum.any?(r.findings, &(&1.module =~ "CoreComponents"))
  end

  test "the app-layer share is reported and never scored by a tier", %{report: r} do
    assert Enum.any?(r.advisory_findings, &(&1.rule == :app_share))
    refute Enum.any?(r.scored_findings, &(&1.rule == :app_share))
  end
end
