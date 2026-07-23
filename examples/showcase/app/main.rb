# api-showcase: render targets, primitives z-order, statics, attr_sprite
# objects, easing, audio channels, geometry. One screen, everything on it.

class Bird
  attr_sprite
  def initialize(x, y)
    @x = x; @y = y; @w = 96; @h = 64
    @path = 'sprites/dragon.png'
    @source_x = 0; @source_y = 0; @source_w = 24; @source_h = 16
  end
end

def tick args
  s = args.state
  s.bird ||= Bird.new(560, 420)
  s.started_at ||= 0

  args.outputs.background_color = [26, 30, 54]

  # statics: shovel the frame ONCE, they persist
  if args.tick_count == 0
    args.outputs.static_borders << [20, 20, 1240, 680, 90, 100, 150]
    args.outputs.static_labels << { x: 640, y: 700, text: 'wyvern api showcase',
                                    size_px: 5, alignment_enum: 1, r: 255, g: 240, b: 120 }
    args.audio[:music] = { input: 'sounds/score.wav', gain: 0.4, looping: true }
  end

  # RENDER TARGET: draw a scene into :minimap, sample it as a sprite twice
  mm = args.outputs[:minimap]
  mm.w = 320
  mm.h = 180
  mm.background_color = [10, 60, 30]
  mm.solids << [10, 10, 300, 20, 40, 160, 80]
  8.times do |i|
    x = (args.tick_count * (i + 1)) % 300
    mm.solids << [x, 40 + i * 16, 14, 10, 255 - i * 20, 120 + i * 15, 60]
  end
  mm.labels << { x: 160, y: 170, text: 'render target', size_px: 2, alignment_enum: 1 }

  args.outputs.sprites << { x: 60, y: 460, w: 320, h: 180, path: :minimap }
  args.outputs.sprites << { x: 420, y: 500, w: 160, h: 90, path: :minimap, angle: 8, a: 200 }

  # PRIMITIVES: mixed types, z in shovel order (solid UNDER sprite UNDER label)
  t = args.easing.ease(s.started_at, args.tick_count, 180, :smooth_stop_quad)
  px = 60 + (760 * t)
  args.outputs.primitives << { x: px, y: 120, w: 220, h: 130, r: 160, g: 60, b: 200, a: 160 }
  s.bird.x = px + 60
  s.bird.y = 150
  s.bird.angle = Math.sin(args.tick_count / 12.0) * 15
  s.bird.source_x = (args.tick_count % 20 < 10) ? 0 : 24
  args.outputs.primitives << s.bird
  args.outputs.primitives << { x: px + 110, y: 260, text: 'primitives!', size_px: 3,
                               alignment_enum: 1, r: 255, g: 255, b: 255 }
  s.started_at = args.tick_count if t >= 1.0

  # geometry + lines: spoke from screen center to the bird, angle in HUD
  c = [640, 360]
  b = [s.bird.x + 48, s.bird.y + 32]
  args.outputs.lines << [c[0], c[1], b[0], b[1], 120, 200, 255, 140]
  ang = args.geometry.angle_to(c, b).round
  args.outputs.labels << { x: 640, y: 380, text: "angle #{ang}", size_px: 2,
                           alignment_enum: 1, r: 120, g: 200, b: 255 }

  # debug collection: topmost, always
  args.outputs.debug << { x: 24, y: 44, text: "tick #{args.tick_count}", size_px: 2, r: 140, g: 150, b: 180 }

  args.gtk.debug_aux = px.to_i
end
