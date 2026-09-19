# Layer-aware ala_lint across the amazin-variants.
#   cd ala_lint && mix run variants_lint.exs
base = "/Users/fluxgate/projects-personal/ala_architecture/amazin-variants"

# The zero_coupled family (v27–v35) shares one ALA layer structure.
zc = [
  {:app,
   [~r/Web\.CartPage/, ~r/Web\.PortalPage/, ~r/Web\.CartLive/, ~r/Web\.PortalLive/, ~r/View$/,
    ~r/\.Manifest$/, ~r/\.Generated$/, ~r/\.CartPage\./, ~r/\.PortalPage\./],
   [peer_ok: true]},
  {:feature, [~r/\.Features\./], [peer_ok: false, unit: ~r/(.*\.Features\.[^.]+)/]},
  {:domain, [~r/\.Domain\./, ~r/ZeroCoupled\.Cart$/], [peer_ok: true]},
  {:platform,
   [~r/\.Effects/, ~r/\.Foundation\./, ~r/\.Gen\./, ~r/\.Web\.Contracts/, ~r/\.Catalog\./,
    ~r/\.Flows$/, ~r/\.Feature\.Intents/, ~r/EffectInterpreter/, ~r/PageCheck/],
   [peer_ok: true]}
]

shop = [
  {:app, [~r/ShopWeb\./], [peer_ok: true]},
  {:feature, [~r/Shop\.(Cart|Wishlist|Undo|Checkout)$/], [peer_ok: false]},
  {:domain, [~r/Shop\.Pricing$/], [peer_ok: true]},
  {:platform, [~r/Shop\.Outcome/], [peer_ok: true]}
]

spec = fn name ->
  cond do
    String.starts_with?(name, "v36") -> shop
    Enum.any?(~w(v27 v28 v29 v30 v31 v33 v34 v35), &String.starts_with?(name, &1)) -> zc
    true -> nil     # pre-ALA amazin family: no consistent ALA layers to tag → layer-blind
  end
end

variants = File.ls!(base) |> Enum.filter(&File.dir?(Path.join([base, &1, "lib"]))) |> Enum.sort()

IO.puts("variant                          | layered | compliance | compliant% | R1 | R3 | R1-detail")
IO.puts(String.duplicate("-", 100))

for v <- variants do
  lib = Path.join([base, v, "lib"])
  opts = case spec.(v) do
    nil -> []
    s -> [layers: s]
  end
  r = AlaLint.analyze(lib, opts)
  layered = if opts == [], do: "no ", else: "yes"
  r1 = Map.get(r.by_rule, :r1, 0)
  r3 = Map.get(r.by_rule, :r3, 0)
  up = Enum.count(r.findings, &(&1.rule == :r1 and &1.message =~ "flows UP"))
  peer = Enum.count(r.findings, &(&1.rule == :r1 and &1.message =~ "cross-peer"))
  detail = if opts == [], do: "(cycles)", else: "up=#{up} peer=#{peer}"
  IO.puts(
    String.pad_trailing(v, 32) <> " | #{layered}     | " <>
      String.pad_leading("#{r.score}/#{r.grade}", 10) <> " | " <>
      String.pad_leading("#{r.breadth_score}%", 10) <> " | " <>
      String.pad_leading("#{r1}", 2) <> " | " <> String.pad_leading("#{r3}", 2) <> " | " <> detail
  )
end
