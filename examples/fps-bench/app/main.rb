def tick(args)
  args.outputs.background_color = [8, 12, 24]
  args.state.cells ||= begin
    cells = []
    200.times do |row|
      100.times do |col|
        cells << [col * 6, row * 6, 5, 5, 70, 150, 230, 220]
      end
    end
    cells
  end
  args.outputs.solids.concat(args.state.cells)
end
