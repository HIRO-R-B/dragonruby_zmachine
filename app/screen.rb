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
    @color        = [25, 0, 50]
    @last_input   = ''
    @max_width    = 125
    @max_lines    = 64
    @cursor       = false
    @cursor_tick  = 0
    @cursor_pos   = 0
    @cursor_text  = ''
    @cursor_label = { x: 10, y: 10, text: @cursor_text, r: 255, g: 255, b: 255, vertical_alignment_enum: 0 }
    @offset       = 0
    @lines        = @max_lines.times.map { '' }
    @labels       = 31.times.map { |i| Label.new @lines, 10, 10 + 22 * i, i }
    @status_line  = [10, 10 + 22 * 32, '', 255, 255, 255]

    args.outputs.static_labels << @labels << @status_line
    args.outputs.static_solids << [0, 10 + 22 * 31, 1280, 28]
  end

  def tick args
    args.outputs.background_color = @color

    input_text_scroll args
    render_cursor args
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

  def render_cursor args
    @cursor_tick ||= args.tick_count
    args.outputs.labels << @cursor_label if @offset == 0
  end

  def render_cursor_blink args
    return unless (@cursor_tick.elapsed_time % 30) == 0
    @cursor = !@cursor
    @cursor ? (@cursor_label.text << '_') : @cursor_label.text.chop!
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

  def cursor_clear
    @cursor_text.clear
    @cursor_pos = 0
  end

  def cursor_kill
    @cursor_text.chop! if @cursor
    @cursor = false
    @cursor_tick = nil
  end

  def cursor_forward count = 1
    cursor_kill
    @cursor_pos += count
    @cursor_text << ' ' * count
  end

  def cursor_back count = 1
    cursor_kill
    @cursor_pos -= count
    count.times { @cursor_text.chop! }
  end

  def add_char char
    cursor_forward
    @lines[0] << char
  end

  def del_char
    cursor_back
    @lines[0].chop!
  end

  def ret
    cursor_clear
    @lines.pop
    @lines.unshift ''
  end

  def print text
    texts = text.to_s.split "\n", -1
    if texts.length > 1
      self.print texts.first
      texts.drop(1).each do |txt|
        ret
        self.print txt
      end
    else
      @lines[0] << text
      cursor_forward text.length
    end

    line_wrap
  end

  def println text
    self.print text
    ret
  end

  def prompt_input max_letters
    input = ''
    init_pos = @lines[0].length

    loop do
      args = Fiber.yield :input

      # Use script input
      script_input = args.state.input
      if script_input
        self.print script_input
        return script_input
      end

      kd = args.inputs.keyboard.key_down
      kh = args.inputs.keyboard.key_held

      # Enter input
      if kd.enter
        @last_input = input.dup
        break ret
      end

      # Get last input
      if kd.up
        input = @last_input.dup
        cursor_clear
        cursor_forward init_pos + input.length
        @lines[0][init_pos..-1] = input
      end

      pos = @cursor_pos - init_pos

      # Cursor left
      hold = kh.left
      cursor_back if pos > 0 && (kd.left || (hold && hold.elapsed?(15)))

      # Cursor right
      hold = kh.right
      cursor_forward if pos < input.length && (kd.right || (hold && hold.elapsed?(15)))

      # Delete
      hold = kh.backspace
      if pos > 0 && (kd.backspace || (hold && hold.elapsed?(15)))
        @lines[0].slice! @cursor_pos - 1
        input.slice! pos - 1
        cursor_back
      end

      # Typing
      char = args.inputs.text[0]
      next unless char
      if input.length < max_letters
        if 31 < char.ord && char.ord < 127
          @lines[0].insert @cursor_pos, char
          input.insert pos, char
          cursor_forward
        end
      end
    end

    input
  end
end
