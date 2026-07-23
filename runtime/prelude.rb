# wyvern prelude — the DragonRuby-style surface, in Ruby.
# Games only ever see DragonRuby idioms: `def tick args`, shovel primitives
# into args.outputs (solids/sprites/labels/lines/borders/sounds), read
# args.inputs (pad-first: buttons + analog), persist on args.state.

WY_BTN_A      = 1 << 0
WY_BTN_B      = 1 << 1
WY_BTN_X      = 1 << 2
WY_BTN_Y      = 1 << 3
WY_BTN_L      = 1 << 4
WY_BTN_R      = 1 << 5
WY_BTN_START  = 1 << 6
WY_BTN_SELECT = 1 << 7
WY_BTN_UP     = 1 << 8
WY_BTN_DOWN   = 1 << 9
WY_BTN_LEFT   = 1 << 10
WY_BTN_RIGHT  = 1 << 11

class WyOpenState
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

  # DragonRuby-style: a fresh nested open entity.
  #   args.state.player ||= args.state.new_entity(:player, x: 0, y: 0)
  def new_entity(_name = nil, props = nil)
    WyOpenState.new(props)
  end

  def clear!
    @h = {}
  end
end

class WyKeys
  attr_reader :left_analog_x_perc, :left_analog_y_perc,
              :right_analog_x_perc, :right_analog_y_perc

  def initialize(bits, prev_bits, lx = 0, ly = 0, rx = 0, ry = 0)
    @bits = bits
    @prev = prev_bits
    @left_analog_x_perc  = lx / 32767.0
    @left_analog_y_perc  = -ly / 32767.0  # DragonRuby: up is positive
    @right_analog_x_perc = rx / 32767.0
    @right_analog_y_perc = -ry / 32767.0
  end

  def held?(mask)
    (@bits & mask) != 0
  end

  def left;   held?(WY_BTN_LEFT);   end
  def right;  held?(WY_BTN_RIGHT);  end
  def up;     held?(WY_BTN_UP);     end
  def down;   held?(WY_BTN_DOWN);   end
  def space;  held?(WY_BTN_A);      end
  def a;      held?(WY_BTN_A);      end
  def b;      held?(WY_BTN_B);      end
  def x;      held?(WY_BTN_X);      end
  def y;      held?(WY_BTN_Y);      end
  def l1;     held?(WY_BTN_L);      end
  def r1;     held?(WY_BTN_R);      end
  def start;  held?(WY_BTN_START);  end
  def select; held?(WY_BTN_SELECT); end

  def key_down
    WyKeyEdges.new(@bits, @prev)
  end

  def key_held
    self
  end
end

class WyKeyEdges
  def initialize(bits, prev)
    @bits = bits
    @prev = prev
  end

  def edge?(mask)
    (@bits & mask) != 0 && (@prev & mask) == 0
  end

  def left;   edge?(WY_BTN_LEFT);   end
  def right;  edge?(WY_BTN_RIGHT);  end
  def up;     edge?(WY_BTN_UP);     end
  def down;   edge?(WY_BTN_DOWN);   end
  def space;  edge?(WY_BTN_A);      end
  def a;      edge?(WY_BTN_A);      end
  def b;      edge?(WY_BTN_B);      end
  def x;      edge?(WY_BTN_X);      end
  def y;      edge?(WY_BTN_Y);      end
  def l1;     edge?(WY_BTN_L);      end
  def r1;     edge?(WY_BTN_R);      end
  def start;  edge?(WY_BTN_START);  end
  def select; edge?(WY_BTN_SELECT); end
end

class WyInputs
  attr_reader :keyboard, :controller_one

  def initialize(bits, prev_bits, lx, ly, rx, ry)
    @keyboard = WyKeys.new(bits, prev_bits, lx, ly, rx, ry)
    @controller_one = @keyboard
  end
end

class WyOutputs
  attr_reader :solids, :borders, :labels, :lines, :sprites, :sounds
  attr_accessor :background_color

  def initialize
    @solids = []
    @borders = []
    @labels = []
    @lines = []
    @sprites = []
    @sounds = []
    @background_color = [0, 0, 0]
  end
end

# DragonRuby-style geometry helpers. Rects are [x, y, w, h] arrays or
# hashes with :x/:y/:w/:h (both idioms appear in real DR code).
module WyGeometry
  def self.rect(r)
    r.is_a?(Hash) ? [r[:x] || 0, r[:y] || 0, r[:w] || 0, r[:h] || 0] : r
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

  def self.distance(a, b)
    dx = (a[0] || a[:x]) - (b[0] || b[:x])
    dy = (a[1] || a[:y]) - (b[1] || b[:y])
    Math.sqrt(dx * dx + dy * dy)
  end

  def self.center(r)
    x, y, w, h = rect(r)
    [x + w / 2.0, y + h / 2.0]
  end
end

class WyGtk
  def debug_mark(id)
    Wyvern.mark(id.to_i)
  end

  def notify!(msg)
    Wyvern.log(msg.to_s)
  end

  def debug_score=(v)
    Wyvern.debug_set(0, v.to_i)
  end

  def debug_aux=(v)
    Wyvern.debug_set(1, v.to_i)
  end

  # cart SRAM: 64 u32 slots, persisted by the host (save_ptr/save_size)
  def save_u32(slot, v)
    Wyvern.save_u32(slot.to_i, v.to_i)
  end

  def load_u32(slot)
    Wyvern.load_u32(slot.to_i)
  end
end

class WyArgs
  attr_reader :state, :outputs, :gtk
  attr_accessor :inputs

  def initialize
    @state = WyOpenState.new
    @outputs = WyOutputs.new
    @gtk = WyGtk.new
  end

  def geometry
    WyGeometry
  end

  def tick_count
    ($__wy_tick || 0)
  end

  def grid
    { x: 0, y: 0, w: 1280, h: 720 }
  end
end

module Kernel
  def puts(*msgs)
    msgs.each { |m| Wyvern.log(m.to_s) }
    nil
  end

  # DragonRuby-style require: loads another .rb from the cart's assets, once.
  #   require 'app/enemies.rb'   (or 'enemies' — 'app/' and '.rb' are optional)
  def require(path)
    p = path.to_s
    p = p[4..-1] if p.start_with?('app/')  # no Regexp in this mruby build
    p += '.rb' unless p.end_with?('.rb')
    $__wy_required ||= {}
    return false if $__wy_required[p]
    $__wy_required[p] = true
    Wyvern.load_script(p)
  end
end

$args = WyArgs.new
$__wy_prev_bits = 0
$__wy_tick = 0

def __wy_num(v, default)
  v.nil? ? default : v.to_i
end

def __wy_label_x(x, text, scale, alignment)
  return x if alignment.nil? || alignment == 0
  w = (6 * text.length - 1) * scale
  alignment == 1 ? x - w / 2 : x - w
end

def __wy_flush(outputs)
  bg = outputs.background_color || [0, 0, 0]
  Wyvern.clear_bg(__wy_num(bg[0], 0), __wy_num(bg[1], 0), __wy_num(bg[2], 0))

  outputs.solids.each do |s|
    if s.is_a?(Hash)
      Wyvern.solid(__wy_num(s[:x], 0), __wy_num(s[:y], 0), __wy_num(s[:w], 0), __wy_num(s[:h], 0),
                   __wy_num(s[:r], 0), __wy_num(s[:g], 0), __wy_num(s[:b], 0), __wy_num(s[:a], 255))
    else
      Wyvern.solid(__wy_num(s[0], 0), __wy_num(s[1], 0), __wy_num(s[2], 0), __wy_num(s[3], 0),
                   __wy_num(s[4], 0), __wy_num(s[5], 0), __wy_num(s[6], 0), __wy_num(s[7], 255))
    end
  end

  outputs.sprites.each do |s|
    if s.is_a?(Hash)
      Wyvern.sprite(__wy_num(s[:x], 0), __wy_num(s[:y], 0), __wy_num(s[:w], 0), __wy_num(s[:h], 0),
                    s[:path].to_s, (s[:angle] || 0).to_f,
                    __wy_num(s[:source_x], 0), __wy_num(s[:source_y], 0),
                    __wy_num(s[:source_w], 0), __wy_num(s[:source_h], 0),
                    s[:flip_horizontally] ? 1 : 0, s[:flip_vertically] ? 1 : 0,
                    __wy_num(s[:r], 255), __wy_num(s[:g], 255), __wy_num(s[:b], 255),
                    __wy_num(s[:a], 255))
    else
      # [x, y, w, h, path]
      Wyvern.sprite(__wy_num(s[0], 0), __wy_num(s[1], 0), __wy_num(s[2], 0), __wy_num(s[3], 0),
                    s[4].to_s, 0.0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255)
    end
  end

  outputs.borders.each do |s|
    if s.is_a?(Hash)
      Wyvern.border(__wy_num(s[:x], 0), __wy_num(s[:y], 0), __wy_num(s[:w], 0), __wy_num(s[:h], 0),
                    __wy_num(s[:r], 0), __wy_num(s[:g], 0), __wy_num(s[:b], 0), __wy_num(s[:a], 255))
    else
      Wyvern.border(__wy_num(s[0], 0), __wy_num(s[1], 0), __wy_num(s[2], 0), __wy_num(s[3], 0),
                    __wy_num(s[4], 0), __wy_num(s[5], 0), __wy_num(s[6], 0), __wy_num(s[7], 255))
    end
  end

  outputs.lines.each do |l|
    if l.is_a?(Hash)
      Wyvern.line(__wy_num(l[:x], 0), __wy_num(l[:y], 0), __wy_num(l[:x2], 0), __wy_num(l[:y2], 0),
                  __wy_num(l[:r], 0), __wy_num(l[:g], 0), __wy_num(l[:b], 0), __wy_num(l[:a], 255))
    else
      Wyvern.line(__wy_num(l[0], 0), __wy_num(l[1], 0), __wy_num(l[2], 0), __wy_num(l[3], 0),
                  __wy_num(l[4], 0), __wy_num(l[5], 0), __wy_num(l[6], 0), __wy_num(l[7], 255))
    end
  end

  outputs.labels.each do |l|
    if l.is_a?(Hash)
      text = l[:text].to_s
      scale = __wy_num(l[:size_px], 3)
      x = __wy_label_x(__wy_num(l[:x], 0), text, scale, l[:alignment_enum])
      Wyvern.label(x, __wy_num(l[:y], 0), text, scale,
                   __wy_num(l[:r], 255), __wy_num(l[:g], 255), __wy_num(l[:b], 255))
    else
      # [x, y, text, size_px, r, g, b]
      Wyvern.label(__wy_num(l[0], 0), __wy_num(l[1], 0), l[2].to_s, __wy_num(l[3], 3),
                   __wy_num(l[4], 255), __wy_num(l[5], 255), __wy_num(l[6], 255))
    end
  end

  outputs.sounds.each do |snd|
    if snd.is_a?(String)
      Wyvern.sound(snd, 1.0, 0)
    elsif snd.is_a?(Hash)
      if snd[:freq]
        Wyvern.beep(__wy_num(snd[:freq], 440), __wy_num(snd[:frames], 6))
      else
        path = (snd[:path] || snd[:input]).to_s
        Wyvern.sound(path, (snd[:gain] || 1.0).to_f, snd[:looping] ? 1 : 0)
      end
    end
  end
end

# Called by the C shim once per frame: pad-0 buttons + analog sticks.
def __wyvern_frame(bits, lx, ly, rx, ry)
  args = $args
  args.inputs = WyInputs.new(bits, $__wy_prev_bits, lx, ly, rx, ry)
  args.outputs.solids.clear
  args.outputs.sprites.clear
  args.outputs.borders.clear
  args.outputs.lines.clear
  args.outputs.labels.clear
  args.outputs.sounds.clear

  tick args

  __wy_flush(args.outputs)
  $__wy_prev_bits = bits
  $__wy_tick += 1
  nil
end
