# Render-target + mixed-frame test: draws into a named target, then sprites
# it onto the main frame alongside normal solids and labels.
def tick(args)
  args.outputs.background_color = [7, 10, 19]
  t = args.outputs[:mini]
  t.w = 200
  t.h = 200
  t.background_color = [60, 20, 80]
  t.solids << [20, 20, 160, 160, 255, 200, 40, 255]
  t.labels << { x: 30, y: 120, text: 'RT', size_px: 4, r: 0, g: 0, b: 0 }
  args.outputs.solids << [40, 40, 300, 200, 40, 120, 220, 255]
  args.outputs.sprites << { x: 500, y: 200, w: 200, h: 200, path: :mini }
  args.outputs.labels << { x: 40, y: 700, text: 'MAIN FRAME LABEL', size_px: 3, r: 255, g: 255, b: 255 }
end
