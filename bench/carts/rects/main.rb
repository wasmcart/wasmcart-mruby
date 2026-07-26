# Microbench: 1000 opaque array solids — the batched-rect pipeline.
def tick(args)
  args.outputs.background_color = [7, 10, 19]
  s = args.outputs.solids
  i = 0
  t = args.state.tick_count
  while i < 1000
    x = (i * 37 + t) % 1240
    y = (i * 53) % 680
    s << [x, y, 40, 40, (i * 7) % 256, (i * 13) % 256, (i * 29) % 256, 255]
    i += 1
  end
end
