# mruby cross-build for wasmcart (emscripten, no OS deps).
# Host build exists only to produce mrbc/presym; the emscripten build is the
# one the cart links. Lean gem set: compiler (parse .rb at boot, the
# DragonRuby-authentic route), random (srand/rand for deterministic replay),
# and the pure-Ruby stdlib extensions a game actually uses.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gem core: 'mruby-compiler'
end

MRuby::CrossBuild.new('emscripten') do |conf|
  conf.toolchain :clang
  conf.cc.command = 'emcc'
  conf.cc.flags << '-Os'
  conf.cc.flags << '-sSUPPORT_LONGJMP=wasm'
  conf.linker.command = 'emcc'
  conf.linker.flags << '-sSUPPORT_LONGJMP=wasm'
  conf.archiver.command = 'emar'

  conf.gem core: 'mruby-compiler'
  conf.gem core: 'mruby-random'
  conf.gem core: 'mruby-math'
  conf.gem core: 'mruby-sprintf'
  conf.gem core: 'mruby-string-ext'
  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-hash-ext'
  conf.gem core: 'mruby-numeric-ext'
  conf.gem core: 'mruby-object-ext'
  conf.gem core: 'mruby-enum-ext'
  conf.gem core: 'mruby-struct'
  conf.gem core: 'mruby-symbol-ext'
  conf.gem core: 'mruby-kernel-ext'
  conf.gem core: 'mruby-metaprog'
  conf.gem core: 'mruby-error'
end
