defmodule AcceptanceTest do
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "ala_accept_#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(Path.join(@dir, "lib"))

    File.write!(Path.join(@dir, "lib/badge.ex"), """
    defmodule App.Domain.Badge do
      @inherent_labels %{low: "Only a few left today", out: "Out of stock for now"}
      @labels %{empty: "Your cart is empty today"}
      def labels, do: {@inherent_labels, @labels}
      # ala:accept r3 -- retail's own word, kept (checklist R3, domain vocabulary)
      def say, do: "Promo applied for you"
      def other, do: "Low stock warning here"
      # ala:accept r3,r6 lines=2 -- two checks, two lines
      def f1, do: 42
      def f2, do: 43
      # ala:accept r5 -- nothing here fires r5
      def quiet, do: 1
    end
    """)

    File.write!(Path.join(@dir, "lib/page.ex"), """
    defmodule AppWeb.Page do
      use Phoenix.LiveView
      def render(assigns) do
        ~H\"\"\"
        <%!-- ala:accept r11 -- the one loop this page keeps --%>
        <div :for={r <- @rows}>{r}</div>
        \"\"\"
      end
    end
    """)

    layers = [
      {:app, [~r/^AppWeb\./], app: true, peer_ok: true},
      {:domain, [~r/\.Domain\./]}
    ]

    on_exit(fn -> File.rm_rf!(@dir) end)
    {:ok, report: AlaLint.analyze(Path.join(@dir, "lib"), layers: layers, super_strict: true)}
  end

  test "inherent words are not R3 findings; other words still are", %{report: r} do
    r3 = r.findings |> Enum.filter(&(&1.rule == :r3)) |> Enum.map(& &1.message)
    refute Enum.any?(r3, &(&1 =~ "Only a few" or &1 =~ "Out of stock"))
    assert Enum.any?(r3, &(&1 =~ "Your cart is empty"))
    assert Enum.any?(r3, &(&1 =~ "Low stock warning"))
    assert [{"App.Domain.Badge", _, :inherent_labels, 2}] = r.inherent
  end

  test "accepted findings leave the score and are listed", %{report: r} do
    assert Enum.any?(r.accepted, &(&1.rule == :r3 and &1.message =~ "Promo applied"))
    refute Enum.any?(r.findings, &(&1.message =~ "Promo applied"))
    assert Enum.any?(r.accepted, &(&1.rule == :r6 and &1.line in [9, 10]))
    assert Enum.any?(r.accepted, &(&1.rule == :r3 and &1.line in [9, 10]))
    assert length(r.acceptances) == 4
    text = AlaLint.Report.to_text(r)
    assert text =~ "Accepted by hand:"
    assert text =~ "1 covering nothing"
    listing = AlaLint.Report.accepted_listing(r)
    assert listing =~ "Inherent text declared (1"
    assert listing =~ "@inherent_labels"
    assert listing =~ "badge.ex:5  r3  lines 6  -- retail's own word"
    assert listing =~ "↳ [r3] line 6"
    assert listing =~ "badge.ex:8  r3,r6  lines 9–10"
    assert listing =~ "covers nothing"
  end

  test "a HEEx acceptance covers a template finding", %{report: r} do
    assert Enum.any?(r.accepted, &(&1.rule == :r11))
    refute Enum.any?(r.findings, &(&1.rule == :r11 and &1.message =~ ":for"))
  end

  test "an unknown check name fails the run" do
    assert_raise ArgumentError, ~r/ala:accept names no such check: nope/, fn ->
      AlaLint.Acceptance.scan("# ala:accept nope\ndef x, do: 1\n", "x.ex")
    end
  end
end
