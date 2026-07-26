# Microbench: same 1000 rects but the Ruby arrays are built ONCE and
# concat'd per frame — isolates marshal+render cost from Ruby list building.
def tick(args)
  args.outputs.background_color = [7, 10, 19]
  args.state.cached ||= begin
    list = []
    i = 0
    while i < 1000
      list << [(i * 37) % 1240, (i * 53) % 680, 40, 40,
               (i * 7) % 256, (i * 13) % 256, (i * 29) % 256, 255]
      i += 1
    end
    list
  end
  args.outputs.solids.concat(args.state.cached)
end
