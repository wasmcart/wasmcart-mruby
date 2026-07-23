# your game starts here — pure Ruby, DragonRuby-style.
# run it:  ./run.sh   (or: npx wasmcart .)
def tick args
  args.state.x ||= 600
  args.state.hue ||= 0

  args.outputs.background_color = [24, 28, 52]

  args.state.x += 5 if args.inputs.keyboard.right
  args.state.x -= 5 if args.inputs.keyboard.left
  args.state.hue = (args.state.hue + 1) % 255 if args.inputs.keyboard.key_down.a

  args.outputs.labels << { x: 640, y: 600, text: 'hello from ruby!', size_px: 6, alignment_enum: 1, r: 255, g: 240, b: 120 }
  args.outputs.labels << { x: 640, y: 520, text: 'd-pad moves. A recolors.', size_px: 3, alignment_enum: 1, r: 180, g: 190, b: 220 }
  args.outputs.solids << [args.state.x, 300, 80, 80, 90, 220 - args.state.hue / 2, 130 + args.state.hue / 3]
end
