# FLAPPY WYVERN — a DragonRuby-style game on the full wyvern surface:
# spritesheet animation with rotation, WAV sound effects, geometry helpers,
# centered mixed-case labels, deterministic rand. Pure DragonRuby idiom:
# def tick args, args.state, args.inputs, shovel into args.outputs.


DRAGON_X = 280
DRAGON_W = 96
DRAGON_H = 64
GAP_H    = 285
PILLAR_W = 96
SPEED    = 4

def spawn_pillar args
  gap_y = 140 + rand(720 - 280 - GAP_H)
  args.state.pillars << { x: 1280, gap_y: gap_y, scored: false }
end

def reset_round args
  args.state.dragon_y   = 360
  args.state.vel        = 0
  args.state.pillars    = []
  args.state.score      = 0
  args.state.flap_anim  = 0
  args.state.round_tick = 0
end

def dragon_rect args
  # slightly forgiving hitbox inside the sprite
  [DRAGON_X + 12, args.state.dragon_y + 10, DRAGON_W - 30, DRAGON_H - 22]
end

def draw_dragon args
  wing_up = args.state.flap_anim > 0
  tilt = (args.state.vel || 0) * 3.2
  tilt = 28 if tilt > 28
  tilt = -35 if tilt < -35
  args.outputs.sprites << {
    x: DRAGON_X, y: args.state.dragon_y.to_i, w: DRAGON_W, h: DRAGON_H,
    path: 'sprites/dragon.png',
    source_x: wing_up ? 0 : 24, source_y: 0, source_w: 24, source_h: 16,
    angle: args.state.phase == :dead ? -90 : tilt,
    a: args.state.phase == :dead ? 200 : 255,
  }
end

# vertical sky gradient: deep zenith to pale horizon (drawn as bands)
SKY_TOP    = [46, 88, 172]
SKY_BOTTOM = [158, 200, 238]
SKY_BANDS  = 18

def draw_sky args
  args.outputs.background_color = SKY_TOP
  band_h = (720.0 / SKY_BANDS).ceil
  SKY_BANDS.times do |i|
    t = i / (SKY_BANDS - 1.0)
    r = (SKY_TOP[0] + (SKY_BOTTOM[0] - SKY_TOP[0]) * t).to_i
    g = (SKY_TOP[1] + (SKY_BOTTOM[1] - SKY_TOP[1]) * t).to_i
    b = (SKY_TOP[2] + (SKY_BOTTOM[2] - SKY_TOP[2]) * t).to_i
    args.outputs.solids << [0, 720 - (i + 1) * band_h, 1280, band_h, r, g, b]
  end
end

# three cloud layers: far = small, slow, faint; near = big, fast, bright.
CLOUD_LAYERS = [
  { speed: 8, scale: 2, alpha: 90,  ys: [560, 620], count: 3, gap: 520 },
  { speed: 4, scale: 3, alpha: 140, ys: [500, 590], count: 3, gap: 610 },
  { speed: 2, scale: 5, alpha: 205, ys: [430, 640], count: 2, gap: 860 },
]

def draw_clouds args
  t = args.tick_count
  CLOUD_LAYERS.each_with_index do |lay, li|
    lay[:count].times do |i|
      path = (li + i).odd? ? 'sprites/cloud2.png' : 'sprites/cloud1.png'
      w = (path.end_with?('1.png') ? 64 : 52) * lay[:scale]
      h = (path.end_with?('1.png') ? 36 : 32) * lay[:scale]
      span = 1280 + w + lay[:gap]
      cx = 1280 - ((t / lay[:speed]) + i * lay[:gap] + li * 210) % span
      cy = lay[:ys][i % lay[:ys].length] - (li * 8)
      args.outputs.sprites << { x: cx, y: cy, w: w, h: h, path: path, a: lay[:alpha] }
    end
  end
end

# a pipe half: gradient-baked sprites (body column + capped end).
def draw_pipe args, x, y, h, cap
  return if h <= 0
  cap_h = 30
  body_y, body_h = cap == :cap_top ? [y, h - cap_h] : [y + cap_h, h - cap_h]
  cap_y = cap == :cap_top ? y + h - cap_h : y

  args.outputs.sprites << { x: x, y: body_y, w: PILLAR_W, h: body_h, path: 'sprites/pipe_body.png' }
  args.outputs.sprites << { x: x - 6, y: cap_y, w: PILLAR_W + 12, h: cap_h, path: 'sprites/pipe_cap.png' }
  # soft shadow where the cap overhangs the body (tinted 1x1 white pixel)
  sy = cap == :cap_top ? cap_y - 7 : cap_y + cap_h
  args.outputs.sprites << { x: x, y: sy, w: PILLAR_W, h: 7, path: 'sprites/px.png', r: 0, g: 0, b: 0, a: 70 }
end

def tick args
  args.state.phase ||= :title
  args.state.hiscore ||= args.gtk.load_u32(0)  # from cart SRAM
  reset_round args if args.state.pillars.nil?

  draw_sky args
  draw_clouds args
  # ground: lit turf over soil with a shadow line
  args.outputs.solids << [0, 0, 1280, 40, 90, 70, 40]
  args.outputs.solids << [0, 34, 1280, 6, 70, 54, 30]
  args.outputs.solids << [0, 40, 1280, 8, 120, 170, 70]
  args.outputs.solids << [0, 46, 1280, 2, 160, 205, 100]

  flap = args.inputs.keyboard.key_down.up || args.inputs.keyboard.key_down.space

  case args.state.phase
  when :title
    args.state.dragon_y = 360 + (args.tick_count % 60 < 30 ? 6 : 0)
    args.state.flap_anim = args.tick_count % 30 < 15 ? 1 : 0
    args.outputs.labels << { x: 640, y: 520, text: 'FLAPPY WYVERN', size_px: 8, alignment_enum: 1, r: 255, g: 240, b: 80 }
    args.outputs.labels << { x: 640, y: 400, text: 'tap A or space to flap', size_px: 4, alignment_enum: 1 }
    args.outputs.labels << { x: 640, y: 340, text: 'a DragonRuby-style cart', size_px: 3, alignment_enum: 1, r: 210, g: 220, b: 255 }
    if flap
      args.state.phase = :play
      args.gtk.debug_mark 2
      puts 'round start'
    end

  when :play
    args.state.vel = 6 if flap          # flappy sets velocity, never adds
    args.state.vel -= 0.3               # gravity
    args.state.vel = -7 if args.state.vel < -7   # gentler terminal fall
    args.state.dragon_y += args.state.vel
    args.state.flap_anim = flap ? 8 : (args.state.flap_anim - 1)
    args.outputs.sounds << 'sounds/flap.wav' if flap

    args.state.round_tick += 1
    spawn_pillar args if args.state.round_tick % 105 == 30
    args.state.pillars.each { |p| p[:x] -= SPEED }
    args.state.pillars.reject! { |p| p[:x] < -PILLAR_W }

    dead = args.state.dragon_y < 48 || args.state.dragon_y > 720 - DRAGON_H
    dbox = dragon_rect args
    args.state.pillars.each do |p|
      if !p[:scored] && p[:x] + PILLAR_W < DRAGON_X
        p[:scored] = true
        args.state.score += 1
        args.outputs.sounds << 'sounds/score.wav'
        args.gtk.debug_mark 4 if args.state.score % 5 == 0
      end
      bottom = [p[:x], 48, PILLAR_W, p[:gap_y] - 48]
      top    = [p[:x], p[:gap_y] + GAP_H, PILLAR_W, 720 - (p[:gap_y] + GAP_H)]
      dead ||= args.geometry.intersect_rect?(dbox, bottom) || args.geometry.intersect_rect?(dbox, top)
    end

    if dead
      args.state.phase = :dead
      if args.state.score > args.state.hiscore
        args.state.hiscore = args.state.score
        args.gtk.save_u32 0, args.state.hiscore  # persist to cart SRAM
      end
      args.outputs.sounds << 'sounds/hit.wav'
      args.gtk.debug_mark 3
      puts "game over at score #{args.state.score}"
    end

  when :dead
    args.outputs.labels << { x: 640, y: 500, text: 'GAME OVER', size_px: 8, alignment_enum: 1, r: 255, g: 90, b: 60 }
    args.outputs.labels << { x: 640, y: 400, text: "score: #{args.state.score}", size_px: 5, alignment_enum: 1 }
    args.outputs.labels << { x: 640, y: 340, text: "hiscore: #{args.state.hiscore}", size_px: 4, alignment_enum: 1, r: 255, g: 240, b: 80 }
    args.outputs.labels << { x: 640, y: 280, text: 'tap A to try again', size_px: 3, alignment_enum: 1, r: 210, g: 220, b: 255 }
    if flap
      reset_round args
      args.state.phase = :play
      args.gtk.debug_mark 2
    end
  end

  # pillars: shaded cylinders with capped ends; dragon drawn last, on top
  args.state.pillars.each do |p|
    draw_pipe args, p[:x], 48, p[:gap_y] - 48, :cap_top
    top_y = p[:gap_y] + GAP_H
    draw_pipe args, p[:x], top_y, 720 - top_y, :cap_bottom
  end
  draw_dragon args

  # HUD
  args.outputs.labels << [24, 700, "score: #{args.state.score}", 4] unless args.state.phase == :title

  # mirror named state into the harness debug slots
  args.gtk.debug_score = args.state.score
  args.gtk.debug_aux   = args.state.dragon_y.to_i
end
