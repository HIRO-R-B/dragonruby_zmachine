

def tick args
  if args.tick_count == 0
    ZM = ZMachine.new true
  end

  ZM.tick args
end

class ZMachine
  attr_accessor :memory, :pc, :stack, :header

  def initialize debug = false
    @debug = debug
    @opcode_table = {
      # 2op instr
      1   => :_je,
      # 2   => :_jl,
      # 3   => :_jg,
      # 6   => :_jin,
      10  => :_test_attr,
      13  => :_store,
      15  => :_loadw,
      # 16  => :_loadb,
      20  => :_add,
      21  => :_sub,
      # 1op instr
      128 => :_jz,
      139 => :_ret,
      140 => :_jump,
      # 0op instr
      178 => :_print,
      187 => :_new_line,
      # VARop instr
      224 => :_call,
      225 => :_storew,
      227 => :_put_prop,
    }
    @operands = []

    @pc         = 0
    @stack      = []
    @stack_addr = 0 # To keep track of routine local stacks
    @memory     = $gtk.read_file('app/zork1.dat').bytes

    @header = {}
    @header.version            = read_byte
    @header.flags1             = read_byte
    @header.release            = read_word
    @header.high_memory_addr   = read_word
    @header.pc_init            = read_word
    @header.dict_addr          = read_word
    @header.object_table_addr  = read_word
    @header.global_table_addr  = read_word
    @header.static_memory_addr = read_word
    @header.flags2             = read_word
    @header.serial_code        = read_byte.chr +
                                 read_byte.chr +
                                 read_byte.chr +
                                 read_byte.chr +
                                 read_byte.chr +
                                 read_byte.chr
    @header.abbr_table_addr    = read_word
    @header.story_length       = read_word
    @header.checksum           = read_word

    @pc = @header.pc_init

    dbg { [@header, 'Header'] }
    # dbg { [31.times.map { |n| get_property_default n }, 'Property Defaults Table'] }

    if @debug
      @main = Fiber.new do |args|
        loop do
          loop do
            args = Fiber.yield
            break if args.inputs.mouse.button_left unless @stop
            break if @stop && args.inputs.mouse.button_right || args.inputs.mouse.click
          end

          @_count ||= 0
          @_count += 1
          puts "======== :: #{@_count}"
          @stop = read_instruction
        end
      end
    else
      @main = Fiber.new do |args|
        loop do
          value = read_instruction
          if value
            args = Fiber.yield value
          end
        end
      end
    end
  end

  def tick args
    @main.resume args if @main.alive?
  end

  def serialize
    { pc: @pc, stack: @stack }
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
      puts "* ZM Operands\n- #{@operands.map { |v| v.to_s 16 }} #{block.call if block}"
    when :addr
      puts "* ZM Operands Addr #{block.call.map { |v| v.is_a?(Symbol) ? v : v.to_s(16) }}"
    when :print
      puts "\n* ZM PRINT\n#{block.call}\n"
    else
      return puts "\n" unless block
      obj, str = block.call
      return puts "* ZM #{str}\n- #{obj}" if str
      puts "* ZM #{obj}"
    end
  end

  def dbg_var var
    case var
    when 0x00
      'SP'
    when 0x01..0x0f
      "L#{(var - 0x01).to_s 16}"
    when 0x10..0xff
      n    = var - 0x10
      addr = @header.global_table_addr + n * 2
      "G#{n.to_s 16}:#{addr.to_s 16}"
    end
  end
  # DEBUG ################################

  def seek pc
    @pc = pc
  end
  alias_method :jump, :seek

  def peek_byte pc = @pc
    @memory[pc]
  end

  def peek_word pc = @pc
    (@memory[pc] << 8) | @memory[pc + 1]
  end

  def peek_bytes pc = @pc, count = 1
    count.times.map { |i| @memory[pc + i] }
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
    @memory[addr] = value
  end

  def write_word addr, value
    @memory[addr]     = value >> 8
    @memory[addr + 1] = value & 0xff
  end

  # The object table is held in dynamic memory and its byte address is stored in the word at $0a in the header. (Recall that objects have flags attached called attributes, numbered from 0 upward, and variables attached called properties, numbered from 1 upward. An object need not provide every property.)
  # The table begins with a block known as the property defaults table. This contains 31 words in Versions 1 to 3 and 63 in Versions 4 and later. When the game attempts to read the value of property n for an object which does not provide property n, the n-th entry in this table is the resulting value.

  def get_property_default n
    peek_word @header.object_table_addr + 2 * n
  end

  # the 32 attribute flags     parent     sibling     child   properties
  # ---32 bits in 4 bytes---   ---3 bytes------------------  ---2 bytes--
  # parent, sibling and child must all hold valid object numbers.
  # The properties pointer is the byte address of the list of properties attached to the object.
  # Attributes 0 to 31 are flags (at any given time, they are either on (1) or off (0)) and are stored topmost bit first: e.g., attribute 0 is stored in bit 7 of the first byte, attribute 31 is stored in bit 0 of the fourth.

  # Each object has its own property table. Each of these can be anywhere in dynamic memory (indeed, a game can legally change an object's properties table address in play, provided the new address points to another valid properties table). The header of a property table is as follows:
  #  text-length     text of short name of object
  # -----byte----   --some even number of bytes---
  # where the text-length is the number of 2-byte words making up the text, which is stored in the usual format. (This means that an object's short name is limited to 765 Z-characters.) After the header, the properties are listed in descending numerical order. (This order is essential and is not a matter of convention.)

  # In Versions 1 to 3, each property is stored as a block
  # size byte     the actual property data
  #              ---between 1 and 8 bytes--
  # where the size byte is arranged as 32 times the number of data bytes minus one, plus the property number. A property list is terminated by a size byte of 0. (It is otherwise illegal for a size byte to be a multiple of 32.)

  def get_object_addr object
    object_tree_addr = @header.object_table_addr + 62
    addr = object_tree_addr + 9 * (object - 1)
  end

  def get_object_property object, property
    prop_table_addr = peek_word get_object_addr(object) + 7
    text_length     = peek_byte prop_table_addr
    prop_list_addr  = prop_table_addr + (text_length * 2) + 1

    # size byte = 32 * size - 1 + prop_num
    # 111     11111
    # size-1  prop_num

    ptr = prop_list_addr
    loop do
      size_byte = peek_byte ptr
      ptr += 1

      num = size_byte & 0x1f
      size = (size_byte >> 5) + 1

      return ptr, size if property == num
      break if property > num

      ptr += size
    end
  end

  def object_attribute? object, attribute
    obj_addr = get_object_addr object
    byte_loc = attribute.idiv 8

    byte = obj_addr + byte_loc

    (peek_byte(byte) & (0x80 >> (attribute & 7))) > 0
  end

  def read_instruction
    ## Instruction Form
    # Opcode              1 || 2 bytes
    # (Operand Types)     1 || 2 bytes; 4 || 8 2bit fields
    # Operands            0 .. 8; 1 || 2 bytes each
    # (Store variable)    1 byte
    # (Branch offset)     1 or 2 bytes
    # (Text to print)     An encoded string (of unlimited length)

    ## Operand Type
    # 0b00    Large constant (0 to 65535)    2 bytes
    # 0b01    Small constant (0 to 255)      1 byte
    # 0b10    Variable                       1 byte
    # 0b11    Omitted altogether             0 bytes

    ## Variable number
    # 0x00          Top of stack
    # 0x01..0x0f    local variables of routine
    # 0x10..0xff    global variables

    ## Instruction form: top two bits of opcode
    # 0x11    variable
    #           bit 5 opcount
    #             0b0  = 2op
    #             else = VAR
    #           bottom 5 bits = opcode number
    # 0x10    short
    #           bits 4 && 5 give optype
    #             0b11 = 0op
    #             else = 1op of optype
    #           bottom 4 bits = opcode number
    # else    long
    #           opcount = 2op
    #           bottom 5 bits = opcode number

    opcode_addr = @pc
    opcode_byte = read_byte
    opcode      = opcode_byte

    @operands.clear

    case opcode_byte
    when 0x00..0x1f # long      2op  small constant, small constant
      opcode = opcode_byte & 0x1f
      byte_1 = read_byte
      byte_2 = read_byte
      @operands.push byte_1, byte_2

      dbg :addr { [:small, byte_1, :small, byte_2] }
    when 0x20..0x3f # long      2op  small constant, variable
      opcode = opcode_byte & 0x1f
      byte_1 = read_byte
      byte_2 = read_byte
      @operands.push byte_1, get_var(byte_2)

      dbg :addr { [:small, byte_1, :var, byte_2, dbg_var(byte_2)] }
    when 0x40..0x5f # long      2op  variable, small constant
      opcode = opcode_byte & 0x1f
      byte_1 = read_byte
      byte_2 = read_byte
      @operands.push get_var(byte_1), byte_2

      dbg :addr { [:var, byte_1, dbg_var(byte_1), :small, byte_2] }
    when 0x60..0x7f # long      2op  variable, variable
      opcode = opcode_byte & 0x1f
      byte_1 = read_byte
      byte_2 = read_byte
      @operands.push get_var(byte_1), get_var(byte_2)

      dbg :addr { [:var, byte_1, dbg_var(byte_1), :var, byte_2, dbg_var(byte_2)] }
    when 0x80..0x8f # short     1op  large constant
      opcode = 128 + (opcode_byte & 0xf)
      word = read_word
      @operands << word

      dbg :addr { [:large, word] }
    when 0x90..0x9f # short     1op  small constant
      opcode = 128 + (opcode_byte & 0xf)
      byte = read_byte
      @operands << byte

      dbg :addr { [:small, byte] }
    when 0xa0..0xaf # short     1op  variable
      opcode = 128 + (opcode_byte & 0xf)
      byte = read_byte
      @operands << get_var(byte)

      dbg :addr { [:var, byte, dbg_var(byte)] }
    when 0xb0..0xbf # short     0op
      opcode = 176 + (opcode_byte & 0xf)
      if opcode_byte == 0xbe # long || extended opcode in next byte in v5
      end
    when 0xc0..0xdf # variable  2op  optypes in next byte
      operands_byte = read_byte

      6.step(0, -2).each do |i|
        bit = (operands_byte >> i) & 3
        case bit
        when 0 # large constant
          @operands << read_word
        when 1 # short constant
          @operands << read_byte
        when 2 # variable
          var_addr = read_byte
          @operands << get_var(var_addr)
        when 3
          break
        end
      end
    when 0xe0..0xff # variable  VAR  optypes in next byte(s)
      operands_byte = read_byte

      6.step(0, -2).each do |i|
        bit = (operands_byte >> i) & 3
        case bit
        when 0 # large constant
          @operands << read_word
        when 1 # short constant
          @operands << read_byte
        when 2 # variable
          var_addr = read_byte
          @operands << get_var(var_addr)
        when 3
          break
        end
      end
    end

    instruction = @opcode_table[opcode]

    dbg { [@stack, 'stack']}
    dbg
    dbg { "PC 0x#{opcode_addr.to_s(16)} | byte 0x#{opcode_byte.to_s 16} | opcode #{opcode} #{instruction}" }

    raise "no instruction" unless instruction
    value = send instruction

    dbg

    value
  end

  # Instructions which test a condition are called "branch" instructions.
  # The branch information is stored in one or two bytes, indicating what to do with the result of the test.
  # If bit 7 of the first byte is 0, a branch occurs when the condition was false; if 1, then branch is on true.
  # If bit 6 is set, then the branch occupies 1 byte only, and the "offset" is in the range 0 to 63, given in the bottom 6 bits.
  # If bit 6 is clear, then the offset is a signed 14-bit number given in bits 0 to 5 of the first byte followed by all 8 of the second.
  # An offset of 0 means "return false from the current routine", and 1 means "return true from the current routine".
  # Otherwise, a branch moves execution to the instruction at address
  #   Address after branch data + Offset - 2.

  def branch test
    byte_1 = read_byte
    jump_cond = (byte_1 & (1 << 7)) > 0 # check bit 7

    if test == jump_cond
      if (byte_1 & (1 << 6)) > 0 # check bit 6
        offset = byte_1 & 0x3f
      else
        byte_2 = read_byte
        offset = ((byte_1 & 0x1f) << 8) | byte_2
      end

      if offset == 0 || offset == 1
        opcode_return offset
      else
        jump @pc + offset - 2
      end
    end

    dbg { [[test == jump_cond, @pc.to_s(16)], 'branch'] }
  end

  def opcode_return value # Check _call, to understand this? kinda?
    @stack.pop until @stack.length == @stack_addr
    op, pc, addr = @stack.pop
    @stack_addr = @stack.length - 1
    store addr, value
    @pc = pc
  end

  def get_var var
    case var
    when 0x00
      @stack.last
    when 0x01..0x0f
      @stack[@stack_addr][var - 0x01]
    when 0x10..0xff
      peek_word @header.global_table_addr + (var - 0x10) * 2
    end
  end

  def store var, value
    case var
    when 0x00        # top of stack
      @stack << value
    when 0x01..0x0f  # local variables
      @stack[@stack_addr][var - 0x01] = value
    when 0x10..0xff  # global variables
      global_addr = @header.global_table_addr + (var - 0x10) * 2
      write_word global_addr, value # globals are word size?
    end
  end

  # Z-machine text is a sequence of ZSCII character codes (ZSCII is a system similar to ASCII: see S 3.8 below). These ZSCII values are encoded into memory using a string of Z-characters. The process of converting between Z-characters and ZSCII values is given in SS 3.2 to 3.7 below.
  # Text in memory consists of a sequence of 2-byte words. Each word is divided into three 5-bit 'Z-characters', plus 1 bit left over, arranged as
  #    --first byte-------   --second byte---
  #    7    6 5 4 3 2  1 0   7 6 5  4 3 2 1 0
  #    bit  --first--  --second---  --third--
  # The bit is set only on the last 2-byte word of the text, and so marks the end.
  def read_z_char_sequence
    words = []
    loop do
      word = read_word
      words << word
      break if (word >> 15) == 1
    end

    words
      .map { |word| 10.step(0, -5).map { |i| (word >> i) & 0x1f } }
      .flatten
  end

  def peek_z_char_sequence addr
    pc = @pc
    jump addr
    zseq = read_z_char_sequence
    jump pc

    zseq
  end

  # In Versions 3 and later, the current alphabet is always A0 unless changed for 1 character only: Z-characters 4 and 5 are shift characters. Thus 4 means "the next character is in A1" and 5 means "the next is in A2". There are no shift lock characters.
  # An indefinite sequence of shift or shift lock characters is legal (but prints nothing).
  # In Versions 3 and later, Z-characters 1, 2 and 3 represent abbreviations, sometimes also called 'synonyms' (for traditional reasons): the next Z-character indicates which abbreviation string to print. If z is the first Z-character (1, 2 or 3) and x the subsequent one, then the interpreter must look up entry 32(z-1)+x in the abbreviations table and print the string at that word address. In Version 2, Z-character 1 has this effect (but 2 and 3 do not, so there are only 32 abbreviations).
  # Abbreviation string-printing follows all the rules of this section except that an abbreviation string must not itself use abbreviations and must not end with an incomplete multi-Z-character construction (see S 3.6.1 below).
  # Z-character 6 from A2 means that the two subsequent Z-characters specify a ten-bit ZSCII character code: the next Z-character gives the top 5 bits and the one after the bottom 5.
  # The remaining Z-characters are translated into ZSCII character codes using the "alphabet table".
  # The Z-character 0 is printed as a space (ZSCII 32).
  # In Versions 2 to 4, the alphabet table for converting Z-characters into ZSCII character codes is as follows:
  #    Z-char 6789abcdef0123456789abcdef
  # current   --------------------------
  #   A0      abcdefghijklmnopqrstuvwxyz
  #   A1      ABCDEFGHIJKLMNOPQRSTUVWXYZ
  #   A2       ^0123456789.,!?_#'"/\-:()
  #           --------------------------
  # (Character 6 in A2 is printed as a space here, but is not translated using the alphabet table: see S 3.4 above. Character 7 in A2, written here as a circumflex ^, is a new-line.) For example, in alphabet A1 the Z-character 12 is translated as a capital G (ZSCII character code 71).

  A0 = 'abcdefghijklmnopqrstuvwxyz'
  A1 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  A2 = " \n0123456789.,!?_#'\"/\\-:()"

  def parse_zchar_sequence zeq
    zeq = zeq.dup.reverse
    result = []

    loop do
      break if zeq.empty?

      zchar = zeq.pop
      case zchar
      when 0
        result << ' '
      when 1..3
          zchar_1 = zeq.pop
          result << parse_zchar_sequence(get_abbreviation(zchar, zchar_1))
      when 4..5
        zchar_1 = zeq.pop
        break if zchar_1 == 5 || zchar_1 == nil
        if zchar == 5 && zchar_1 == 6
          zchar_2 = zeq.pop
          zchar_3 = zeq.pop
          zc = ((zchar_1 << 5) | zchar_2)
          result << zc.chr
        else
          result.push zchar_to_zscii zchar_1, (zchar == 4 ? A1 : A2)
        end
      else
        result << (zchar_to_zscii zchar, A0)
      end
    end

    result.flatten.join
  end

  def zchar_to_zscii zchar, alphabet
    alphabet[zchar - 6]
  end

  def get_abbreviation zchar_1, zchar_2
    idx = 32 * (zchar_1 - 1) + zchar_2
    addr = peek_word @header.abbr_table_addr + idx * 2
    zeq = peek_z_char_sequence addr * 2
  end

  def read_zscii_text
    zeq  = read_z_char_sequence
    text = parse_zchar_sequence zeq

    dbg { [zeq, 'zchar sequence'] }

    text
  end

  ## Opcode implementations
  # 2op ################################
  #1
  def _je
    branch @operands[0] == @operands[1]

    dbg :operands
  end
  #3
  def _jg
    branch @operands[0] > @operands[1]

    dbg :operands
  end
  #10
  def _test_attr # variable, small constant
    object, attribute = @operands
    branch object_attribute?(object, attribute)

    dbg :operands
  end
  #13
  def _store
    store @operands[0], @operands[1]

    dbg :operands
  end
  #15
  def _loadw
    var = read_byte
    mem_addr = @operands[0] + 2 * @operands[1]
    word = peek_word mem_addr
    store var, word

    dbg :operands { [:var, var.to_s(16)] }
  end
  #20
  def _add
    var = read_byte
    a, b = @operands.pack('ss').unpack('ss')
    store var, a + b

    dbg :operands { [:var, var.to_s(16)]}
  end
  #21
  def _sub # variable, small constant
    var = read_byte
    a, b = @operands.pack('ss').unpack('ss')
    store var, a - b

    dbg :operands { [:var, var.to_s(16)] }
  end

  # 1op ################################
  #128
  def _jz
    branch @operands[0] == 0

    dbg :operands
  end
  #139
  def _ret
    opcode_return @operands[0]

    dbg :operands
  end
  #140
  def _jump # operand is a 2-byte signed offset
    offset = @operands.pack('s').unpack('s')[0]
    jump @pc + offset - 2

    dbg :operands
  end

  # 0op ################################
  #178
  def _print
    text = read_zscii_text # TODO:: Printing implementation? Console fiddling needed??

    dbg :print { text }
  end
  #187
  def _new_line
    dbg { [0, ":new_line"]}
    puts ''
  end

  # VAR ################################
  #224
  def _call
    addr = read_byte

    if @operands[0] == 0
      store 0x00, 0
    else
      store 0x00, [:call, @pc, addr]

      @operands[0] *= 2
      @pc = @operands[0]

      var_count = read_byte                    # routine local var count
      raise "not a routine" unless (0..15).=== var_count

      store 0x00, var_count.map { read_word }  # setting values
      @operands[1..-1].each_with_index { |v, i| @stack.last[i] = v }

      @stack_addr = @stack.length - 1
    end

    dbg :operands
  end
  #225
  def _storew
    array, word_index, value = @operands
    write_word array + 2 * word_index, value

    dbg :operands
  end
  #227
  def _put_prop
    object, property, value = @operands
    addr, size = get_object_property object, property

    if size == 1
      write_byte addr + 1, value
    elsif size == 2
      write_word addr + 1, value
    else
      raise "put_prop size #{size}"
    end

    dbg :operands
  end
end
