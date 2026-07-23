# wyvern prelude - the DragonRuby-style surface, in Ruby (embedded into the
# engine wasm at build time). Games see only DragonRuby idioms.
#
# Render order per frame: render targets first (so they're samplable), then
# solids, sprites, primitives, labels, lines, borders, debug - statics before
# their per-tick counterparts within each collection. Primitives and debug
# accept ANY primitive type (hash with inferred or explicit primitive_marker,
# array, or an object with attr_sprite-style accessors) and draw in shovel
# order - the z-ordering tool.

WC_BTN_A      = 1 << 0
WC_BTN_B      = 1 << 1
WC_BTN_X      = 1 << 2
WC_BTN_Y      = 1 << 3
WC_BTN_L      = 1 << 4
WC_BTN_R      = 1 << 5
WC_BTN_START  = 1 << 6
WC_BTN_SELECT = 1 << 7
WC_BTN_UP     = 1 << 8
WC_BTN_DOWN   = 1 << 9
WC_BTN_LEFT   = 1 << 10
WC_BTN_RIGHT  = 1 << 11

module Wasmcart
class OpenState
  def initialize(seed = nil)
    @h = {}
    seed.each { |k, v| @h[k.to_sym] = v } if seed
  end

  def method_missing(name, *a)
    s = name.to_s
    if s.end_with?("=")
      @h[s[0...-1].to_sym] = a[0]
    else
      @h[name]
    end
  end

  def respond_to_missing?(_n, _priv = false)
    true
  end

  def new_entity(_name = nil, props = nil)
    OpenState.new(props)
  end

  def clear!
    @h = {}
  end
end

# ── input ────────────────────────────────────────────────────────────

class Keys
  attr_reader :left_analog_x_perc, :left_analog_y_perc,
              :right_analog_x_perc, :right_analog_y_perc

  def initialize(bits, prev_bits, lx = 0, ly = 0, rx = 0, ry = 0)
    @bits = bits
    @prev = prev_bits
    @left_analog_x_perc  = lx / 32767.0
    @left_analog_y_perc  = -ly / 32767.0
    @right_analog_x_perc = rx / 32767.0
    @right_analog_y_perc = -ry / 32767.0
  end

  def held?(mask)
    (@bits & mask) != 0
  end

  def left;   held?(WC_BTN_LEFT);   end
  def right;  held?(WC_BTN_RIGHT);  end
  def up;     held?(WC_BTN_UP);     end
  def down;   held?(WC_BTN_DOWN);   end
  def space;  held?(WC_BTN_A);      end
  def a;      held?(WC_BTN_A);      end
  def b;      held?(WC_BTN_B);      end
  def x;      held?(WC_BTN_X);      end
  def y;      held?(WC_BTN_Y);      end
  def l1;     held?(WC_BTN_L);      end
  def r1;     held?(WC_BTN_R);      end
  def start;  held?(WC_BTN_START);  end
  def select; held?(WC_BTN_SELECT); end

  def key_down
    KeyEdges.new(@bits, @prev)
  end

  def key_held
    self
  end
end

class KeyEdges
  def initialize(bits, prev)
    @bits = bits
    @prev = prev
  end

  def edge?(mask)
    (@bits & mask) != 0 && (@prev & mask) == 0
  end

  def left;   edge?(WC_BTN_LEFT);   end
  def right;  edge?(WC_BTN_RIGHT);  end
  def up;     edge?(WC_BTN_UP);     end
  def down;   edge?(WC_BTN_DOWN);   end
  def space;  edge?(WC_BTN_A);      end
  def a;      edge?(WC_BTN_A);      end
  def b;      edge?(WC_BTN_B);      end
  def x;      edge?(WC_BTN_X);      end
  def y;      edge?(WC_BTN_Y);      end
  def l1;     edge?(WC_BTN_L);      end
  def r1;     edge?(WC_BTN_R);      end
  def start;  edge?(WC_BTN_START);  end
  def select; edge?(WC_BTN_SELECT); end
end

class Inputs
  attr_reader :keyboard, :controllers,
              :controller_one, :controller_two, :controller_three, :controller_four

  # pads: [[bits, lx, ly, rx, ry] x4], prevs: previous frame's button bits x4
  def initialize(pads, prevs)
    @controllers = []
    4.times do |i|
      p = pads[i] || [0, 0, 0, 0, 0]
      @controllers << Keys.new(p[0], prevs[i] || 0, p[1], p[2], p[3], p[4])
    end
    @controller_one, @controller_two, @controller_three, @controller_four = @controllers
    @keyboard = @controller_one
  end
end

# ── outputs ──────────────────────────────────────────────────────────

class RenderTarget
  attr_reader :solids, :sprites, :labels, :lines, :borders, :primitives
  attr_accessor :w, :h, :background_color

  def initialize
    @solids = []
    @sprites = []
    @labels = []
    @lines = []
    @borders = []
    @primitives = []
    @w = 0
    @h = 0
    @background_color = nil
  end

  def transient!
    self
  end

  def any_content?
    !(@solids.empty? && @sprites.empty? && @labels.empty? &&
      @lines.empty? && @borders.empty? && @primitives.empty?)
  end

  def clear_frame!
    @solids.clear; @sprites.clear; @labels.clear
    @lines.clear; @borders.clear; @primitives.clear
  end
end

class Outputs
  attr_reader :solids, :sprites, :labels, :lines, :borders, :sounds,
              :primitives, :debug,
              :static_solids, :static_sprites, :static_labels,
              :static_lines, :static_borders, :static_primitives,
              :targets
  attr_accessor :background_color

  def initialize
    @solids = []; @sprites = []; @labels = []; @lines = []; @borders = []
    @primitives = []; @debug = []; @sounds = []
    @static_solids = []; @static_sprites = []; @static_labels = []
    @static_lines = []; @static_borders = []; @static_primitives = []
    @targets = {}
    @background_color = [0, 0, 0]
  end

  # args.outputs[:minimap] - a named render target, usable as a sprite via
  # path: :minimap. Re-rendered on ticks you shovel into it.
  def [](name)
    @targets[name.to_sym] ||= RenderTarget.new
  end

  def clear_frame!
    @solids.clear; @sprites.clear; @labels.clear; @lines.clear
    @borders.clear; @primitives.clear; @debug.clear; @sounds.clear
    @targets.each_value { |t| t.clear_frame! }
  end
end

end # module Wasmcart

# ── attr_sprite-style mixins (shovel OBJECTS, DragonRuby OO idiom) ───

class Module
  def attr_rect
    attr_accessor :x, :y, :w, :h
  end

  def attr_sprite
    attr_rect
    attr_accessor :path, :angle, :a, :r, :g, :b,
                  :source_x, :source_y, :source_w, :source_h,
                  :flip_horizontally, :flip_vertically
    define_method(:primitive_marker) { :sprite }
  end

  def attr_label
    attr_accessor :x, :y, :text, :size_px, :alignment_enum, :a, :r, :g, :b
    define_method(:primitive_marker) { :label }
  end

  def attr_line
    attr_accessor :x, :y, :x2, :y2, :a, :r, :g, :b
    define_method(:primitive_marker) { :line }
  end
end

# ── geometry ─────────────────────────────────────────────────────────

module Wasmcart
module Geometry
  def self.rect(r)
    if r.is_a?(Hash)
      [r[:x] || 0, r[:y] || 0, r[:w] || 0, r[:h] || 0]
    elsif r.is_a?(Array)
      r
    else
      [r.x || 0, r.y || 0, r.w || 0, r.h || 0]
    end
  end

  def self.xy(p)
    if p.is_a?(Hash)
      [p[:x] || 0, p[:y] || 0]
    elsif p.is_a?(Array)
      [p[0] || 0, p[1] || 0]
    else
      [p.x || 0, p.y || 0]
    end
  end

  def self.intersect_rect?(a, b)
    ax, ay, aw, ah = rect(a)
    bx, by, bw, bh = rect(b)
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
  end

  def self.inside_rect?(inner, outer)
    ix, iy, iw, ih = rect(inner)
    ox, oy, ow, oh = rect(outer)
    ix >= ox && iy >= oy && ix + iw <= ox + ow && iy + ih <= oy + oh
  end

  def self.point_inside_rect?(point, r)
    px, py = xy(point)
    rx, ry, rw, rh = rect(r)
    px >= rx && px < rx + rw && py >= ry && py < ry + rh
  end

  def self.distance(a, b)
    ax, ay = xy(a)
    bx, by = xy(b)
    Math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
  end

  def self.angle_to(a, b)
    ax, ay = xy(a)
    bx, by = xy(b)
    Math.atan2(by - ay, bx - ax) * 180.0 / Math::PI
  end

  def self.angle_from(a, b)
    angle_to(b, a)
  end

  def self.center(r)
    x, y, w, h = rect(r)
    [x + w / 2.0, y + h / 2.0]
  end

  def self.scale_rect(r, ratio, anchor_x = 0.5, anchor_y = 0.5)
    x, y, w, h = rect(r)
    nw = w * ratio
    nh = h * ratio
    [x + (w - nw) * anchor_x, y + (h - nh) * anchor_y, nw, nh]
  end

  def self.line(l)
    if l.is_a?(Hash)
      [l[:x] || 0, l[:y] || 0, l[:x2] || 0, l[:y2] || 0]
    elsif l.is_a?(Array)
      l
    else
      [l.x || 0, l.y || 0, l.x2 || 0, l.y2 || 0]
    end
  end

  # do two line SEGMENTS cross?
  def self.line_intersect?(l1, l2)
    ax, ay, bx, by = line(l1)
    cx, cy, dx, dy = line(l2)
    d1 = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    d2 = (bx - ax) * (dy - ay) - (by - ay) * (dx - ax)
    d3 = (dx - cx) * (ay - cy) - (dy - cy) * (ax - cx)
    d4 = (dx - cx) * (by - cy) - (dy - cy) * (bx - cx)
    ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
  end

  def self.find_intersect_rect(r, rects)
    rects.each { |o| return o if intersect_rect?(r, o) }
    nil
  end

  def self.find_all_intersect_rect(r, rects)
    rects.select { |o| intersect_rect?(r, o) }
  end

  # cubic bezier over scalars (use per axis), t in 0..1
  def self.cubic_bezier(t, a, b, c, d)
    u = 1.0 - t
    (u * u * u * a) + (3 * u * u * t * b) + (3 * u * t * t * c) + (t * t * t * d)
  end

  # de Casteljau over any number of scalar control points
  def self.bezier(t, *points)
    pts = points.flatten
    while pts.length > 1
      nxt = []
      (pts.length - 1).times { |i| nxt << pts[i] + (pts[i + 1] - pts[i]) * t }
      pts = nxt
    end
    pts[0]
  end

  # which side of the line (as a ray a->b) does the point fall on?
  # :left, :right, or :on - DragonRuby's ray_test
  def self.ray_test(point, l)
    px, py = xy(point)
    ax, ay, bx, by = line(l)
    d = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    return :on if d == 0
    d > 0 ? :left : :right
  end

  # rotate a point by degrees around an anchor (default the origin)
  def self.rotate_point(point, angle_degrees, around = nil)
    px, py = xy(point)
    cx, cy = around ? xy(around) : [0, 0]
    rad = angle_degrees * Math::PI / 180.0
    cs = Math.cos(rad)
    sn = Math.sin(rad)
    dx = px - cx
    dy = py - cy
    [cx + dx * cs - dy * sn, cy + dx * sn + dy * cs]
  end
end

# ── easing (args.easing.ease) ────────────────────────────────────────

module Easing
  def self.apply_def(t, d)
    case d
    when :identity then t
    when :flip then 1.0 - t
    when :quad then t * t
    when :cube then t * t * t
    when :quart then t * t * t * t
    when :quint then t * t * t * t * t
    when :smooth_start_quad then t * t
    when :smooth_stop_quad then 1.0 - (1.0 - t) * (1.0 - t)
    when :smooth_stop_cube then 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
    else t
    end
  end

  # ease(start_tick, now, duration, :quad) -> 0..1 progress through curves.
  def self.ease(start_tick, now, duration, *defs)
    return 1.0 if duration <= 0
    t = (now - start_tick).to_f / duration
    t = 0.0 if t < 0
    t = 1.0 if t > 1
    defs = [:identity] if defs.empty?
    defs.each { |d| t = apply_def(t, d) }
    t
  end
end

end # module Wasmcart

# ── numeric sugar ────────────────────────────────────────────────────

class Numeric
  def to_radians
    self * Math::PI / 180.0
  end

  def to_degrees
    self * 180.0 / Math::PI
  end

  def sign
    return 0 if self == 0
    self > 0 ? 1 : -1
  end

  # ticks since self (treating self as a start tick)
  def elapsed_time(now = nil)
    (now || tick_count) - self
  end

  # DragonRuby's sprite-animation one-liner. self = the tick the animation
  # started. Returns the current frame number, or nil when not started /
  # finished (non-repeating).
  #   sprite.source_x = 24 * (started_at.frame_index(4, 6, true) || 0)
  def frame_index(count = nil, hold_for = nil, repeat = nil, repeat_index = 0)
    if count.is_a?(Hash)
      h = count
      count = h[:count]
      hold_for = h[:hold_for] || 1
      repeat = h[:repeat]
      repeat_index = h[:repeat_index] || 0
    end
    hold_for = 1 if hold_for.nil? || hold_for < 1
    elapsed = tick_count - self
    return nil if elapsed < 0 || count.nil? || count < 1
    idx = elapsed / hold_for
    return idx if idx < count
    return nil unless repeat
    loop_len = count - repeat_index
    return repeat_index if loop_len < 1
    repeat_index + ((idx - count) % loop_len)
  end
end

# ── audio channels: args.audio[:music] = { input: 'song.wav', looping: true } ─

module Wasmcart
class Audio
  def initialize
    @entries = {}
  end

  def []=(key, opts)
    key = key.to_sym
    delete(key)
    return nil if opts.nil?
    path = (opts[:input] || opts[:path]).to_s
    gain = (opts[:gain] || 1.0).to_f
    looping = opts[:looping] ? 1 : 0
    ch = WC.sound(path, gain, looping)
    if ch >= 0
      @entries[key] = { opts: opts, channel: ch, gain: gain, pitch: 1.0, paused: false, playtime: 0.0 }
      WC.sound_pitch(ch, opts[:pitch].to_f) if opts[:pitch]
      WC.sound_paused(ch, 1) if opts[:paused]
      WC.sound_seek(ch, opts[:playtime].to_f) if opts[:playtime].is_a?(Numeric) && opts[:playtime] > 0
    end
    opts
  end

  def [](key)
    e = @entries[key.to_sym]
    e ? e[:opts] : nil
  end

  def delete(key)
    e = @entries.delete(key.to_sym)
    WC.sound_stop(e[:channel]) if e
    nil
  end

  def keys
    @entries.keys
  end

  def sync!
    @entries.keys.each do |k|
      e = @entries[k]
      o = e[:opts]
      g = (o[:gain] || 1.0).to_f
      if g != e[:gain]
        WC.sound_gain(e[:channel], g)
        e[:gain] = g
      end
      p = (o[:pitch] || 1.0).to_f
      if p != e[:pitch]
        WC.sound_pitch(e[:channel], p)
        e[:pitch] = p
      end
      paused = o[:paused] ? true : false
      if paused != e[:paused]
        WC.sound_paused(e[:channel], paused ? 1 : 0)
        e[:paused] = paused
      end
      # playtime: game WRITES to seek; the engine refreshes it each tick
      if o[:playtime].is_a?(Numeric) && e[:playtime] && (o[:playtime] - e[:playtime]).abs > 0.25
        WC.sound_seek(e[:channel], o[:playtime].to_f)
      end
      t = WC.sound_playtime(e[:channel])
      o[:playtime] = t if t >= 0
      e[:playtime] = o[:playtime]
      @entries.delete(k) if !paused && !WC.sound_playing(e[:channel])
    end
  end
end

# ── gtk namespace ────────────────────────────────────────────────────

class Gtk
  def debug_mark(id)
    WC.mark(id.to_i)
  end

  def notify!(msg)
    WC.log(msg.to_s)
  end

  def debug_score=(v)
    WC.debug_set(0, v.to_i)
  end

  def debug_aux=(v)
    WC.debug_set(1, v.to_i)
  end

  # cart SRAM: 64 u32 slots, persisted by the host (save_ptr/save_size)
  def save_u32(slot, v)
    WC.save_u32(slot.to_i, v.to_i)
  end

  def load_u32(slot)
    WC.load_u32(slot.to_i)
  end

  # [w, h] a label with this text/size (and optional TTF font) will occupy
  def calcstringbox(text, size_px = 3, font = '')
    WC.text_size(text.to_s, size_px.to_i, font.to_s)
  end
end

class Args
  attr_reader :state, :outputs, :gtk, :audio
  attr_accessor :inputs

  def initialize
    @state = OpenState.new
    @outputs = Outputs.new
    @gtk = Gtk.new
    @audio = Audio.new
  end

  def geometry
    Geometry
  end

  def easing
    Easing
  end

  def tick_count
    ($__wc_tick || 0)
  end

  def grid
    { x: 0, y: 0, w: 1280, h: 720 }
  end
end

end # module Wasmcart

module Kernel
  def puts(*msgs)
    msgs.each { |m| WC.log(m.to_s) }
    nil
  end

  def tick_count
    ($__wc_tick || 0)
  end

  # DragonRuby-style require: loads another .rb from the cart's assets, once.
  def require(path)
    p = path.to_s
    p = p[4..-1] if p.start_with?('app/')
    p += '.rb' unless p.end_with?('.rb')
    $__wc_required ||= {}
    return false if $__wc_required[p]
    $__wc_required[p] = true
    WC.load_script(p)
  end
end

$args = Wasmcart::Args.new
$__wc_prev_pads = [0, 0, 0, 0]
$__wc_tick = 0

# ── the renderer: hash / array / object primitives, one code path ────

def __wc_num(v, default)
  v.nil? ? default : v.to_i
end

def __wc_prop(o, key, default)
  if o.is_a?(Hash)
    v = o[key]
    v.nil? ? default : v
  elsif o.respond_to?(key)
    v = o.send(key)
    v.nil? ? default : v
  else
    default
  end
end

def __wc_sprite_path(v)
  v.is_a?(Symbol) ? "@rt:#{v}" : v.to_s
end

def __wc_draw_solid(s)
  if s.is_a?(Array)
    WC.solid(__wc_num(s[0], 0), __wc_num(s[1], 0), __wc_num(s[2], 0), __wc_num(s[3], 0),
                 __wc_num(s[4], 0), __wc_num(s[5], 0), __wc_num(s[6], 0), __wc_num(s[7], 255))
  else
    WC.solid(__wc_num(__wc_prop(s, :x, 0), 0), __wc_num(__wc_prop(s, :y, 0), 0),
                 __wc_num(__wc_prop(s, :w, 0), 0), __wc_num(__wc_prop(s, :h, 0), 0),
                 __wc_num(__wc_prop(s, :r, 0), 0), __wc_num(__wc_prop(s, :g, 0), 0),
                 __wc_num(__wc_prop(s, :b, 0), 0), __wc_num(__wc_prop(s, :a, 255), 255))
  end
end

def __wc_draw_border(s)
  if s.is_a?(Array)
    WC.border(__wc_num(s[0], 0), __wc_num(s[1], 0), __wc_num(s[2], 0), __wc_num(s[3], 0),
                  __wc_num(s[4], 0), __wc_num(s[5], 0), __wc_num(s[6], 0), __wc_num(s[7], 255))
  else
    WC.border(__wc_num(__wc_prop(s, :x, 0), 0), __wc_num(__wc_prop(s, :y, 0), 0),
                  __wc_num(__wc_prop(s, :w, 0), 0), __wc_num(__wc_prop(s, :h, 0), 0),
                  __wc_num(__wc_prop(s, :r, 0), 0), __wc_num(__wc_prop(s, :g, 0), 0),
                  __wc_num(__wc_prop(s, :b, 0), 0), __wc_num(__wc_prop(s, :a, 255), 255))
  end
end

def __wc_draw_line(l)
  if l.is_a?(Array)
    WC.line(__wc_num(l[0], 0), __wc_num(l[1], 0), __wc_num(l[2], 0), __wc_num(l[3], 0),
                __wc_num(l[4], 0), __wc_num(l[5], 0), __wc_num(l[6], 0), __wc_num(l[7], 255))
  else
    WC.line(__wc_num(__wc_prop(l, :x, 0), 0), __wc_num(__wc_prop(l, :y, 0), 0),
                __wc_num(__wc_prop(l, :x2, 0), 0), __wc_num(__wc_prop(l, :y2, 0), 0),
                __wc_num(__wc_prop(l, :r, 0), 0), __wc_num(__wc_prop(l, :g, 0), 0),
                __wc_num(__wc_prop(l, :b, 0), 0), __wc_num(__wc_prop(l, :a, 255), 255))
  end
end

def __wc_draw_label(l)
  if l.is_a?(Array)
    WC.label(__wc_num(l[0], 0), __wc_num(l[1], 0), l[2].to_s, __wc_num(l[3], 3),
             __wc_num(l[4], 255), __wc_num(l[5], 255), __wc_num(l[6], 255), 255, '')
  else
    text = __wc_prop(l, :text, '').to_s
    scale = __wc_num(__wc_prop(l, :size_px, 3), 3)
    font = __wc_prop(l, :font, '').to_s
    x = __wc_num(__wc_prop(l, :x, 0), 0)
    align = __wc_prop(l, :alignment_enum, 0)
    if align == 1 || align == 2
      w = WC.text_size(text, scale, font)[0]
      x = align == 1 ? x - w / 2 : x - w
    end
    WC.label(x, __wc_num(__wc_prop(l, :y, 0), 0), text, scale,
             __wc_num(__wc_prop(l, :r, 255), 255), __wc_num(__wc_prop(l, :g, 255), 255),
             __wc_num(__wc_prop(l, :b, 255), 255), __wc_num(__wc_prop(l, :a, 255), 255), font)
  end
end

def __wc_draw_sprite(s)
  if s.is_a?(Array)
    WC.sprite(__wc_num(s[0], 0), __wc_num(s[1], 0), __wc_num(s[2], 0), __wc_num(s[3], 0),
                  __wc_sprite_path(s[4]), 0.0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255)
  else
    WC.sprite(__wc_num(__wc_prop(s, :x, 0), 0), __wc_num(__wc_prop(s, :y, 0), 0),
                  __wc_num(__wc_prop(s, :w, 0), 0), __wc_num(__wc_prop(s, :h, 0), 0),
                  __wc_sprite_path(__wc_prop(s, :path, '')),
                  __wc_prop(s, :angle, 0).to_f,
                  __wc_num(__wc_prop(s, :source_x, 0), 0), __wc_num(__wc_prop(s, :source_y, 0), 0),
                  __wc_num(__wc_prop(s, :source_w, 0), 0), __wc_num(__wc_prop(s, :source_h, 0), 0),
                  __wc_prop(s, :flip_horizontally, false) ? 1 : 0,
                  __wc_prop(s, :flip_vertically, false) ? 1 : 0,
                  __wc_num(__wc_prop(s, :r, 255), 255), __wc_num(__wc_prop(s, :g, 255), 255),
                  __wc_num(__wc_prop(s, :b, 255), 255), __wc_num(__wc_prop(s, :a, 255), 255))
  end
end

# primitives / debug: draw ANY primitive, inferring its type
def __wc_draw_prim(p)
  marker = __wc_prop(p, :primitive_marker, nil)
  marker = nil unless [:solid, :border, :sprite, :label, :line].include?(marker)
  if marker.nil?
    if p.is_a?(Array)
      marker = (p[4].is_a?(String) || p[4].is_a?(Symbol)) ? :sprite : :solid
    elsif !__wc_prop(p, :text, nil).nil?
      marker = :label
    elsif __wc_prop(p, :path, nil)
      marker = :sprite
    elsif !__wc_prop(p, :x2, nil).nil?
      marker = :line
    else
      marker = :solid
    end
  end
  case marker
  when :solid  then __wc_draw_solid(p)
  when :border then __wc_draw_border(p)
  when :sprite then __wc_draw_sprite(p)
  when :label  then __wc_draw_label(p)
  when :line   then __wc_draw_line(p)
  end
end

def __wc_flush_target(t)
  if t.background_color
    bg = t.background_color
    WC.solid(0, 0, t.w > 0 ? t.w : 1280, t.h > 0 ? t.h : 720,
                 __wc_num(bg[0], 0), __wc_num(bg[1], 0), __wc_num(bg[2], 0), 255)
  end
  t.solids.each { |s| __wc_draw_solid(s) }
  t.sprites.each { |s| __wc_draw_sprite(s) }
  t.primitives.each { |p| __wc_draw_prim(p) }
  t.labels.each { |l| __wc_draw_label(l) }
  t.lines.each { |l| __wc_draw_line(l) }
  t.borders.each { |b| __wc_draw_border(b) }
end

def __wc_flush(outputs)
  # render targets first, so this frame's pixels are samplable as sprites
  outputs.targets.each do |name, t|
    next unless t.any_content?
    WC.set_target(name.to_s, t.w, t.h)
    __wc_flush_target(t)
    WC.set_target('', 0, 0)
  end

  bg = outputs.background_color || [0, 0, 0]
  WC.clear_bg(__wc_num(bg[0], 0), __wc_num(bg[1], 0), __wc_num(bg[2], 0))

  outputs.static_solids.each { |s| __wc_draw_solid(s) }
  outputs.solids.each { |s| __wc_draw_solid(s) }
  outputs.static_sprites.each { |s| __wc_draw_sprite(s) }
  outputs.sprites.each { |s| __wc_draw_sprite(s) }
  outputs.static_primitives.each { |p| __wc_draw_prim(p) }
  outputs.primitives.each { |p| __wc_draw_prim(p) }
  outputs.static_labels.each { |l| __wc_draw_label(l) }
  outputs.labels.each { |l| __wc_draw_label(l) }
  outputs.static_lines.each { |l| __wc_draw_line(l) }
  outputs.lines.each { |l| __wc_draw_line(l) }
  outputs.static_borders.each { |b| __wc_draw_border(b) }
  outputs.borders.each { |b| __wc_draw_border(b) }
  outputs.debug.each { |p| __wc_draw_prim(p) }

  outputs.sounds.each do |snd|
    if snd.is_a?(String)
      WC.sound(snd, 1.0, 0)
    elsif snd.is_a?(Hash)
      if snd[:freq]
        WC.beep(__wc_num(snd[:freq], 440), __wc_num(snd[:frames], 6))
      else
        path = (snd[:path] || snd[:input]).to_s
        WC.sound(path, (snd[:gain] || 1.0).to_f, snd[:looping] ? 1 : 0)
      end
    end
  end
end

# Called by the C engine once per frame: 4 pads x (buttons, lx, ly, rx, ry).
def __wasmcart_frame(*v)
  args = $args
  pads = [v[0, 5], v[5, 5], v[10, 5], v[15, 5]]
  $__wc_prev_pads ||= [0, 0, 0, 0]
  args.inputs = Wasmcart::Inputs.new(pads, $__wc_prev_pads)
  args.outputs.clear_frame!
  args.state.tick_count = $__wc_tick

  tick args

  __wc_flush(args.outputs)
  args.audio.sync!
  $__wc_prev_pads = [pads[0][0], pads[1][0], pads[2][0], pads[3][0]]
  $__wc_tick += 1
  nil
end
