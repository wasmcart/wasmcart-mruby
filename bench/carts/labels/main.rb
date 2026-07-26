# Microbench: 40 hash labels — the label pipeline (Tetris-style HUD text).
def tick(args)
  args.outputs.background_color = [7, 10, 19]
  l = args.outputs.labels
  i = 0
  t = args.state.tick_count
  while i < 40
    l << { x: 40 + (i % 4) * 300, y: 40 + (i / 4) * 66 + (t % 2), text: "SCORE 1234567 LINES 89",
           size_px: 2, r: 144, g: 184, b: 202 }
    i += 1
  end
end
