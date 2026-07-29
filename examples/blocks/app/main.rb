# NEON BLOCKS - a polished, controller-first Ruby cart.

BOARD_W = 10
BOARD_H = 20
CELL = 26
BOARD_X = 510
BOARD_Y = 86

COLORS = {
  i: [52, 226, 235],
  o: [255, 213, 70],
  t: [190, 92, 255],
  s: [74, 225, 130],
  z: [255, 86, 115],
  j: [82, 142, 255],
  l: [255, 151, 58]
}

SHAPES = {
  i: [0, 1, 2, 3],
  o: [0, 1, 4, 5],
  t: [1, 4, 5, 6],
  s: [1, 2, 4, 5],
  z: [0, 1, 5, 6],
  j: [0, 4, 5, 6],
  l: [2, 4, 5, 6]
}

PIECES = SHAPES.keys

def empty_board
  Array.new(BOARD_H) { Array.new(BOARD_W) }
end

def reset_game args
  s = args.state
  s.board = empty_board
  s.queue = []
  s.current = nil
  s.next_piece = nil
  s.x = 3
  s.y = 18
  s.rotation = 0
  s.fall_timer = 0
  s.score = 0
  s.lines = 0
  s.level = 1
  s.drop_tick = 0
  s.particles = []
  s.flash = 0
  s.combo = 0
  s.phase = :play
  5.times { s.queue << PIECES[rand(PIECES.length)] }
  spawn_piece args
end

def spawn_particles args, x, y, color, count = 18
  s = args.state
  count.times do |i|
    angle = (i * 0.73) % 6.28
    speed = 1.5 + (i % 5) * 0.7
    s.particles << { x: x, y: y, vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed,
                     life: 24 + (i % 12), color: color }
  end
end

def update_particles args
  s = args.state
  s.particles ||= []
  s.particles.each do |p|
    p[:x] += p[:vx]
    p[:y] += p[:vy]
    p[:vy] -= 0.08
    p[:life] -= 1
  end
  s.particles.reject! { |p| p[:life] <= 0 }
  s.flash = [s.flash - 1, 0].max
end

def spawn_piece args
  s = args.state
  s.current = s.queue.shift
  s.queue << PIECES[rand(PIECES.length)]
  s.next_piece = s.queue[0]
  s.x = 3
  s.y = 18
  s.rotation = 0
  s.phase = :dead if collision?(s.board, s.current, s.x, s.y, s.rotation)
end

def cells_for(piece, rotation, x, y)
  raw = SHAPES[piece]
  cells = raw.map do |n|
    [n % 4, n / 4]
  end
  rotation.times do
    cells = cells.map { |cx, cy| [3 - cy, cx] }
  end
  cells.map { |cx, cy| [x + cx, y + cy] }
end

def collision? board, piece, x, y, rotation
  cells_for(piece, rotation, x, y).any? do |cx, cy|
    cx < 0 || cx >= BOARD_W || cy < 0 || (cy < BOARD_H && board[cy][cx])
  end
end

def lock_piece args
  s = args.state
  cells_for(s.current, s.rotation, s.x, s.y).each do |cx, cy|
    s.board[cy][cx] = s.current if cy >= 0 && cy < BOARD_H
  end

  cleared = 0
  s.board.delete_if do |row|
    full = row.all?
    cleared += 1 if full
    full
  end
  cleared.times { s.board << Array.new(BOARD_W) }
  if cleared > 0
    s.lines += cleared
    s.score += [100, 300, 500, 800][cleared - 1] * s.level
    s.level = 1 + s.lines / 10
    s.combo += 1
    s.flash = 12
    spawn_particles args, BOARD_X + BOARD_W * CELL / 2, BOARD_Y + 8, [255, 226, 100], 12 + cleared * 8
    args.outputs.sounds << { freq: 620 + cleared * 100, frames: 8 }
    args.gtk.debug_mark 4 if cleared >= 2
  else
    s.combo = 0
    args.outputs.sounds << { freq: 180, frames: 4 }
  end
  spawn_piece args
end

def move_piece args, dx, dy
  s = args.state
  return false if collision?(s.board, s.current, s.x + dx, s.y + dy, s.rotation)
  s.x += dx
  s.y += dy
  true
end

def rotate_piece args
  s = args.state
  next_rotation = (s.rotation + 1) % 4
  return if collision?(s.board, s.current, s.x, s.y, next_rotation)
  s.rotation = next_rotation
  args.outputs.sounds << { freq: 420, frames: 3 }
end

def draw_rect args, x, y, w, h, color, alpha = 255
  args.outputs.solids << [x, y, w, h, color[0], color[1], color[2], alpha]
end

def draw_cell args, x, y, color, size = CELL, alpha = 255
  draw_rect args, x + 2, y + 2, size - 4, size - 4, color, alpha
  draw_rect args, x + 4, y + size - 7, size - 8, 2, [255, 255, 255], (alpha * 0.38).to_i
  draw_rect args, x + 4, y + 4, 2, size - 8, [255, 255, 255], (alpha * 0.22).to_i
end

def draw_mini_piece args, piece, x, y
  cells_for(piece, 0, 0, 0).each do |cx, cy|
    draw_cell args, x + cx * 16, y + cy * 16, COLORS[piece], 16
  end
end

def draw_background args
  t = args.tick_count || 0
  args.outputs.background_color = [7, 10, 19]
  draw_rect args, 0, 646, 1280, 74, [12, 18, 31]
  draw_rect args, 0, 58, 1280, 2, [21, 31, 48]
  8.times do |i|
    x = ((t * (i + 1) * 0.35 + i * 190) % 1500) - 110
    draw_rect args, x.to_i, 60, 1, 560, [26, 42, 68], 28
  end
  draw_rect args, 96, 616, 1088, 1, [52, 226, 235], 80
  draw_rect args, 96, 618, 180, 2, [190, 92, 255], 150
  draw_rect args, 1080, 618, 104, 2, [255, 213, 70], 150
end

def draw_panel args, x, y, w, h, title
  draw_rect args, x, y, w, h, [12, 18, 31], 230
  args.outputs.borders << [x, y, w, h, 37, 57, 78, 255]
  draw_rect args, x, y + h - 2, w, 2, [52, 214, 228], 200
  args.outputs.labels << { x: x + 16, y: y + h - 25, text: title,
                           size_px: 2, r: 144, g: 184, b: 202 }
end

def draw_board args
  s = args.state
  draw_rect args, BOARD_X - 14, BOARD_Y - 14, BOARD_W * CELL + 28, BOARD_H * CELL + 28, [4, 6, 16]
  draw_rect args, BOARD_X - 7, BOARD_Y - 7, BOARD_W * CELL + 14, BOARD_H * CELL + 14, [35, 46, 82]
  draw_rect args, BOARD_X - 3, BOARD_Y - 3, BOARD_W * CELL + 6, BOARD_H * CELL + 6, [9, 13, 29]
  BOARD_H.times do |row|
    BOARD_W.times do |col|
      x = BOARD_X + col * CELL
      y = BOARD_Y + row * CELL
      draw_rect args, x + 2, y + 2, CELL - 4, CELL - 4, [13, 17, 37], 220
      piece = s.board[row][col]
      draw_cell args, x, y, COLORS[piece] if piece
    end
  end

  unless s.phase == :dead
    ghost_y = s.y
    ghost_y -= 1 until collision?(s.board, s.current, s.x, ghost_y - 1, s.rotation)
    cells_for(s.current, s.rotation, s.x, ghost_y).each do |cx, cy|
      next if cy < 0 || cy >= BOARD_H
      draw_cell args, BOARD_X + cx * CELL, BOARD_Y + cy * CELL, COLORS[s.current], CELL, 55
    end
    cells_for(s.current, s.rotation, s.x, s.y).each do |cx, cy|
      next if cy < 0 || cy >= BOARD_H
      draw_cell args, BOARD_X + cx * CELL, BOARD_Y + cy * CELL, COLORS[s.current]
    end
  end
  s.particles.each do |p|
    alpha = [p[:life] * 10, 180].min
    size = p[:life] > 12 ? 4 : 2
    draw_rect args, p[:x].to_i, p[:y].to_i, size, size, p[:color], alpha
  end
end

def draw_hud args
  s = args.state
  draw_panel args, 120, 454, 250, 150, 'NEXT'
  draw_mini_piece args, s.next_piece, 235, 505
  draw_panel args, 810, 414, 250, 190, 'SCORE'
  args.outputs.labels << { x: 935, y: 535, text: s.score.to_s, size_px: 5,
                            alignment_enum: 1, r: 255, g: 240, b: 120 }
  args.outputs.labels << { x: 830, y: 475, text: 'LEVEL', size_px: 2, r: 144, g: 184, b: 202 }
  args.outputs.labels << { x: 1035, y: 475, text: s.level.to_s, size_px: 2, alignment_enum: 2, r: 220, g: 235, b: 245 }
  args.outputs.labels << { x: 830, y: 440, text: 'LINES', size_px: 2, r: 144, g: 184, b: 202 }
  args.outputs.labels << { x: 1035, y: 440, text: s.lines.to_s, size_px: 2, alignment_enum: 2, r: 220, g: 235, b: 245 }
end

def draw_overlay args, title, subtitle, color
  draw_rect args, BOARD_X - 5, BOARD_Y + 205, BOARD_W * CELL + 10, 110, [5, 7, 20], 235
  args.outputs.labels << { x: 640, y: 405, text: title, size_px: 5, alignment_enum: 1,
                           r: color[0], g: color[1], b: color[2] }
  args.outputs.labels << { x: 640, y: 350, text: subtitle, size_px: 2, alignment_enum: 1,
                           r: 190, g: 205, b: 235 }
end

def tick args
  s = args.state
  s.phase ||= :title
  s.score ||= 0
  s.lines ||= 0
  s.level ||= 1
  s.current ||= :i
  s.next_piece ||= :o
  s.board ||= empty_board
  s.x ||= 3
  s.y ||= 18
  s.rotation ||= 0
  s.particles ||= []
  s.flash ||= 0
  s.combo ||= 0

  draw_background args
  update_particles args
  args.outputs.labels << { x: 120, y: 695, text: 'NEON BLOCKS', size_px: 4,
                           r: 90, g: 235, b: 255 }
  args.outputs.labels << { x: 120, y: 655, text: 'A CLEAN BLOCK PUZZLE', size_px: 2,
                           r: 130, g: 155, b: 180 }

  if s.phase == :title
    draw_panel args, 120, 454, 250, 150, 'NEXT'
    draw_mini_piece args, :t, 235, 505
    draw_board args
    draw_overlay args, 'READY?', 'PRESS A OR START', [255, 226, 100]
    if args.inputs.controller_one.key_down.a || args.inputs.controller_one.key_down.start
      reset_game args
      args.gtk.debug_mark 2
    end
    return
  end

  if s.phase == :pause
    draw_board args
    draw_hud args
    draw_overlay args, 'PAUSED', 'PRESS START TO RESUME', [120, 220, 255]
    s.phase = :play if args.inputs.controller_one.key_down.start
    return
  end

  if s.phase == :dead
    draw_board args
    draw_hud args
    draw_overlay args, 'GAME OVER', 'PRESS A TO PLAY AGAIN', [255, 100, 145]
    if args.inputs.controller_one.key_down.a
      reset_game args
      args.gtk.debug_mark 2
    end
    return
  end

  input = args.inputs.controller_one
  move_piece args, -1, 0 if input.key_down.left
  move_piece args, 1, 0 if input.key_down.right
  rotate_piece args if input.key_down.x
  if input.key_down.a
    while move_piece(args, 0, -1)
    end
    lock_piece args
  elsif input.down
    s.fall_timer += 3
  end

  s.fall_timer += 1
  interval = [10, 45 - (s.level - 1) * 3].max
  if s.fall_timer >= interval
    s.fall_timer = 0
    lock_piece(args) unless move_piece(args, 0, -1)
  end

  draw_board args
  draw_hud args
  if s.flash > 0
    draw_rect args, BOARD_X, BOARD_Y + 8, BOARD_W * CELL, 4, [255, 239, 126], s.flash * 8
  end
  args.outputs.labels << { x: 120, y: 110, text: 'LEFT / RIGHT  MOVE', size_px: 2, r: 144, g: 184, b: 202 }
  args.outputs.labels << { x: 120, y: 84, text: 'DOWN  SOFT DROP', size_px: 2, r: 144, g: 184, b: 202 }
  args.outputs.labels << { x: 120, y: 58, text: 'X  ROTATE     A  DROP     START  PAUSE', size_px: 2, r: 144, g: 184, b: 202 }
  args.gtk.debug_score = s.score
  args.gtk.debug_aux = s.lines
end
