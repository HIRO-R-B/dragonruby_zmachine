# Built using specifications here
# https://inform-fiction.org/zmachine/standards/z1point1/index.html
# Only need it to run Zork 1, so only made with V3 specs in mind

class ZMachine
  attr_accessor :header, :memory, :quit

  include ZInstructions
  include ZText

  def initialize args, file_name, script: nil, debug: false
    @file_name     = file_name
    @script        = script
    @debug         = debug
    @debug_print   = true

    @pc            = 0
    @stack         = []
    @stack_routine = 0 # To keep track of current routine
    @memory        = args.gtk.read_file(file_name).bytes
    @screen        = Screen.new args
    @commands      = (args.gtk.read_file(script).split("\n") << nil).to_enum if script
    if @commands
      seed = @commands.next.to_i
      srand seed
    end

    set_flags

    @header = {
      version:            read_byte,
      flags1:             read_byte,
      release:            read_word,
      high_memory_addr:   read_word,
      pc_init:            read_word,
      dict_addr:          read_word,
      object_table_addr:  read_word,
      global_table_addr:  read_word,
      static_memory_addr: read_word,
      flags2:             read_word,
      serial_code:       (read_byte.chr +
                          read_byte.chr +
                          read_byte.chr +
                          read_byte.chr +
                          read_byte.chr +
                          read_byte.chr),
      abbr_table_addr:    read_word,
      file_length:        read_word,
      checksum:           read_word,
    }

    # Only handles v3 story files
    raise "Story File is v#{@header.version}" if @header.version != 3

    @pc = @header.pc_init

    @main = Fiber.new do |args|
      loop do
        if @debug
          @_count ||= 0
          @_count += 1
          puts "\n======== :: #{@_count}"
        end

        instr = read_instruction
        raise 'no instruction' unless instr

        cmd = send instr
        case cmd
        when :quit
          @quit = true
          break
        end

        next unless @debug
        loop do
          args = Fiber.yield

          break if args.inputs.mouse.button_left unless cmd == :stop
          break if (cmd == :stop) && args.inputs.mouse.button_right || args.inputs.mouse.click

          if args.inputs.keyboard.key_down.tab
            @debug_print = !@debug_print
            $gtk.notify! "debug printing: #{@debug}"
          end
        end
      end
    end

    dbg { [@header, 'Header'] }

    args.state.data.pc = 0
  end

  def tick args
    state = @main.resume args if @main.alive?
    @screen.tick args

    if @commands && state == :input
      input = @commands.next
      args.state.input = input
      @commands = nil if input.nil?
    end
  end

  def jump pc
    prev_pc = @pc
    @pc = pc

    prev_pc
  end

  def peek_byte pc = @pc
    @memory[pc]
  end

  def peek_word pc = @pc
    (@memory[pc] << 8) | @memory[pc + 1]
  end

  def read_byte
    result = peek_byte
    @pc += 1

    result
  end

  def read_word
    result = peek_word
    @pc += 2

    result
  end

  def write_byte addr, value
    @memory[addr] = uint8 value
  end

  def write_word addr, value
    @memory[addr]     = uint8 (value >> 8)
    @memory[addr + 1] = uint8 value
  end

  def uint8 val
    val & 0xff
  end

  def sint14 val
    val = -(0x2000 - (val & 0x1fff)) if (val & 0x2000) > 0
    val
  end

  def uint16 val
    val & 0xffff
  end

  def sint16 val
    val = -(0x8000 - (val & 0x7fff)) if (val & 0x8000) > 0
    val
  end

  def set_bit val, bit
    val | (1 << bit)
  end

  def set_bits val, *bits
    bits.each { |bit| val = set_bit val, bit }
    val
  end

  def clear_bit val, bit
    val & ~(1 << bit)
  end

  def clear_bits val, *bits
    bits.each { |bit| val = clear_bit val, bit }
    val
  end

  def set_flags
    # flags1
    flags1 = peek_byte 0x01
    # flags1 = (set_bits   flags1,
    #                      4) # No status line
    flags1 = (clear_bits flags1,
                         0) # No color
    write_byte 0x01, flags1

    # flags2
    flags2 = peek_word 0x10
    flags2 = (clear_bits flags2,
                         5, # No mouse support
                         8) # No menu support
    write_word 0x10, flags2
  end

  def zobj obj_id
    ZObject.new self, obj_id
  end

  def serialize
    { pc: @pc }
  end

  def inspect
    serialize.to_s
  end

  def to_s
    serialize.to_s
  end

  # DEBUG ################################
  def dbg arg = nil, &block
    return unless @debug

    case arg
    when :operands
      ops = block.call.map_with_index do |(t, v), i|
        if t == :var
          [(dbg :var { v }), @operands[i]]
        else
          [t, v.to_s(16)]
        end
      end
      puts "* operands: #{ops}"
    when :print
      puts "* PRINT\n#{block.call}\n"
    when :var
      var = block.call
      case var
      when 0x00
        'SP'
      when 0x01..0x0f
        "L#{(var - 0x01).to_s 16}"
      when 0x10..0xff
        n    = var - 0x10
        addr = @header.global_table_addr + n * 2
        "G#{n.to_s 16}"
      end
    else
      return puts "\n" unless block
      puts "* #{arg}: #{block.call}"
    end
  end
  # DEBUG ################################
end
