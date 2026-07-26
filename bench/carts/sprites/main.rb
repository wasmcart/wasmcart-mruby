# Microbench: 300 hash sprites from one atlas image — the sprite pipeline.
def tick(args)
  args.outputs.background_color = [7, 10, 19]
  s = args.outputs.sprites
  i = 0
  t = args.state.tick_count
  while i < 300
    s << { x: (i * 41 + t) % 1216, y: (i * 59) % 656, w: 64, h: 64,
           path: 'sprites/dragon.png' }
    i += 1
  end
end
