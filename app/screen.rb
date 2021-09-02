class Screen
  class Label
    @@offset = 0

    def self.offset
      @@offset
    end

    def self.offset= offset
      @@offset = offset
    end

    def initialize text_array, x, y, i
      @text_array = text_array
      @x = x
      @y = y
      @i = i
    end

    def draw_override ffi
      ffi.draw_label_3 @x, @y, @text_array[@@offset + @i], 0, 0, 255, 255, 255, 255, 'font.ttf', 0, 1
    end
  end

  def initialize args
    @color       = [25, 0, 50]
    @max_width   = 125
    @max_lines   = 64
    @cursor      = false
    @offset      = 0
    @lines       = @max_lines.times.map { '' }
    @labels      = 31.times.map { |i| Label.new @lines, 10, 10 + 22 * i, i }
    @status_line = [10, 10 + 22 * 32, '', 255, 255, 255]
    args.outputs.static_labels << @labels << @status_line
    args.outputs.static_solids << [0, 10 + 22 * 31, 1280, 28]
  end

  def tick args
    args.outputs.background_color = @color

    input_text_scroll args
    render_cursor_blink args
    render_scroll_bar args
  end

  def input_text_scroll args
    mouse = args.inputs.mouse
    if mouse.wheel && args.gtk.console.hidden?
      @offset = (@offset - 2 * mouse.wheel.y).clamp 0, @max_lines - 32
    end
    Label.offset = @offset
  end

  def render_cursor_blink args
    return unless args.tick_count.zmod? 30
    @cursor = !@cursor
    @cursor ? (add_char '_') : del_char
  end

  def render_scroll_bar args
    args.outputs.solids << [1260, @offset / 34 * 692, 20, 40, 255, 255, 255]
  end

  def set_status_line location, score, moves
    text = "Score: #{score} Moves: #{moves}".rjust(@max_width)
    location = location.ljust(49)
    text[0, 49] = location
    @status_line.text = text
  end

  def wrapped_text text
    return nil unless text.length > @max_width
    texts = []
    loop do
      break texts << text if text.length < @max_width
      j = @max_width
      j -= 1 while text[j] != ' '
      texts << text[0, j]
      text = text[(j+1)..-1]
    end

    texts
  end

  def line_wrap
    lines = wrapped_text @lines[0]
    return unless lines
    @lines.shift
    lines.each { |line| @lines.unshift line }
    @lines.pop until @lines.length == @max_lines
  end

  def add_char char
    @lines[0] << char
  end

  def del_char
    @lines[0].chop!
  end

  def cursor_kill
    del_char if @cursor
    @cursor = false
    @offset = 0
  end

  def ret
    cursor_kill
    @lines.pop
    @lines.unshift ''
  end

  def print_del
    cursor_kill
    del_char
  end

  def print text
    cursor_kill
    texts = text.to_s.split "\n", -1
    if texts.length > 1
      self.print texts.first
      texts.drop(1).each do |txt|
        ret
        self.print txt
      end
    else
      @lines[0] << text
    end

    line_wrap
  end

  def println text
    self.print text
    ret
  end

  def prompt_input max_letters
    input = ''

    loop do
      args = Fiber.yield :input

      script_input = args.state.input
      if script_input
        self.print script_input
        return script_input
      end

      kd = args.inputs.keyboard.key_down
      kh = args.inputs.keyboard.key_held

      break if kd.enter

      hold = kh.backspace
      if input.length > 0 && (kd.backspace || (hold && hold.elapsed?(15)))
        print_del
        input.chop!
      end

      char = args.inputs.text[0]
      next unless char
      if input.length < max_letters
        if 31 < char.ord && char.ord < 127
          self.print char
          input << char
        end
      end
    end

    input
  end
end
