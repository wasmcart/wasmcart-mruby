def tick(args)
  matched = /wasmcart/.match('mruby wasmcart')
  args.outputs.labels << {
    x: 80,
    y: 360,
    text: matched ? 'REGEXP OK' : 'REGEXP FAILED',
    size_px: 4,
    r: matched ? 80 : 255,
    g: matched ? 240 : 80,
    b: 160
  }
end
