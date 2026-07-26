# Microbench: empty tick — measures the fixed per-frame floor
# (VM dispatch, inputs build, outputs clear, audio sync).
def tick(args)
  args.outputs.background_color = [7, 10, 19]
end
