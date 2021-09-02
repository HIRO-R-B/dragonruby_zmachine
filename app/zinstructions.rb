# How instructions are encoded
# https://inform-fiction.org/zmachine/standards/z1point1/sect04.html

# How routines are encoded
# https://inform-fiction.org/zmachine/standards/z1point1/sect05.html

module ZInstructions
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

  def read_instruction
    opcode_addr = @pc
    opcode_byte = read_byte

    dbg :stack { "#{@stack}" }
    dbg :PC { "0x#{opcode_addr.to_s 16} | Byte 0x#{opcode_byte.to_s 16}" }

    case opcode_byte
    when 0x00..0x7f, 0xc0..0xdf # 2op
      opcode = opcode_byte & 0x1f
    when 0x80..0xaf # 1op
      opcode = 128 + (opcode_byte & 0xf)
    when 0xb0..0xbf # 0op
      opcode = 176 + (opcode_byte & 0xf)
    when 0xe0..0xff # VAR
      opcode = 224 + (opcode_byte & 0x1f)
    end

    instruction = instruction_table[opcode]
    raise "no instruction #{opcode}" unless instruction
    dbg :opcode { "#{opcode} | #{instruction}" }

    case opcode_byte
    when 0x00..0x1f # long      2op  small constant, small constant
      parse_operands :small, :small
    when 0x20..0x3f # long      2op  small constant, variable
      parse_operands :small, :var
    when 0x40..0x5f # long      2op  variable, small constant
      parse_operands :var, :small
    when 0x60..0x7f # long      2op  variable, variable
      parse_operands :var, :var
    when 0x80..0x8f # short     1op  large constant
      parse_operands :large
    when 0x90..0x9f # short     1op  small constant
      parse_operands :small
    when 0xa0..0xaf # short     1op  variable
      parse_operands :var
    when 0xb0..0xbf # short     0op
      operands.clear
      raise "write this section: parse_opcode" if opcode_byte == 0xbe # long || extended opcode in next byte in v5
    when 0xc0..0xdf # variable  2op  optypes in next byte
      parse_operands variable: true
    when 0xe0..0xff # variable  VAR  optypes in next byte(s)
      parse_operands variable: true
    end

    instruction
  end

  def operands
    @operands ||= []
  end

  def parse_operands *types, variable: false
    ops = variable ? read_var_operands : read_operands(types)
    operands.clear
    ops.each do |type, val|
      operands << (type == :var ? get_var(val) : val)
    end

    dbg :operands { ops }
  end

  def read_operands types
    types.map do |type|
      case type
      when :small then [type, read_byte]
      when :large then [type, read_word]
      when :var   then [type, read_byte]
      end
    end
  end

  def read_var_operands
    operands_byte = read_byte

    types = []
    6.step(0, -2).each do |i|
      case (operands_byte >> i) & 3
      when 0 then types << :large
      when 1 then types << :small
      when 2 then types << :var
      else break
      end
    end

    read_operands types
  end

  def routine var
    if operands[0] == 0
      store 0x00, 0
    else
      @stack << [:call, @pc, var, @stack_routine]
      @stack_routine = @stack.length - 1

      @operands[0] *= 2
      @pc = @operands[0]

      var_count = read_byte # routine local var count
      raise "not a routine" unless (0..15).=== var_count

      @stack << var_count.map { read_word }  # setting values
      @operands[1..-1].each_with_index { |v, i| @stack.last[i] = v }
    end
  end

  def routine_return value
    @stack.pop until @stack.length == @stack_routine + 1
    _, pc, var, stack_routine = @stack.pop
    @stack_routine = stack_routine
    jump pc
    store var, value
  end

  def branch test
    byte_1 = read_byte
    jump_cond = (byte_1 & (1 << 7)) > 0 # check bit 7

    if (byte_1 & (1 << 6)) > 0 # check bit 6
      offset = byte_1 & 0x3f
    else
      byte_2 = read_byte
      offset = sint14 (((byte_1 & 0x3f) << 8) | byte_2)
    end

    if test == jump_cond
      if offset == 0 || offset == 1
        routine_return offset
      else
        jump @pc + offset - 2
      end
    end

    dbg :branch { [test == jump_cond, @pc.to_s(16)] }
  end

  def get_var var
    case var
    when 0x00
      @stack.pop
    when 0x01..0x0f
      @stack[@stack_routine + 1][var - 0x01]
    when 0x10..0xff
      peek_word @header.global_table_addr + 2 * (var - 0x10)
    end
  end

  def store var, value
    case var
    when 0x00        # top of stack
      @stack << (uint16 value)
    when 0x01..0x0f  # local variables
      @stack[@stack_routine + 1][var - 0x01] = (uint16 value)
    when 0x10..0xff  # global variables
      global_addr = @header.global_table_addr + 2 * (var - 0x10)
      write_word global_addr, value # globals are word size?
    end
  end

  def increment var, const = 1
    case var
    when 0x00
      @stack[-1] = uint16(@stack[-1] + const)
    when 0x01..0x0f
      val = @stack[@stack_routine + 1][var - 0x01]
      @stack[@stack_routine + 1][var - 0x01] = uint16(val + const)
    when 0x10..0xff
      global_addr = @header.global_table_addr + 2 * (var - 0x10)
      val = peek_word global_addr
      val += const
      val = uint16 val
      write_word global_addr, val

      val
    end
  end

  def decrement var
    increment var, -1
  end

  def status_line_values
    location = peek_zscii_text (zobj get_var 0x10).name_addr
    score    = sint16 get_var 0x11
    moves    = sint16 get_var 0x12

    return location, score, moves
  end

  def instruction_table
    @instruction_table ||= {
      # 2op instr
      1   => :_je,
      2   => :_jl,
      3   => :_jg,
      4   => :_dec_chk,
      5   => :_inc_chk,
      6   => :_jin,
      7   => :_test,
      8   => :_or,
      9   => :_and,
      10  => :_test_attr,
      11  => :_set_attr,
      12  => :_clear_attr,
      13  => :_store,
      14  => :_insert_obj,
      15  => :_loadw,
      16  => :_loadb,
      17  => :_get_prop,
      18  => :_get_prop_addr,
      19  => :_get_next_prop,
      20  => :_add,
      21  => :_sub,
      22  => :_mul,
      23  => :_div,
      24  => :_mod,

      # 1op instr
      128 => :_jz,
      129 => :_get_sibling,
      130 => :_get_child,
      131 => :_get_parent,
      132 => :_get_prop_len,
      133 => :_inc,
      134 => :_dec,
      135 => :_print_addr,
      137 => :_remove_obj,
      138 => :_print_obj,
      139 => :_ret,
      140 => :_jump,
      141 => :_print_paddr,
      142 => :_load,
      143 => :_not,

      # 0op instr
      176 => :_rtrue,
      177 => :_rfalse,
      178 => :_print,
      179 => :_print_ret,
      181 => :_save,
      182 => :_restore,
      184 => :_ret_popped,
      185 => :_pop,
      186 => :_quit,
      187 => :_new_line,
      188 => :_show_status,
      189 => :_verify,

      # VARop instr
      224 => :_call,
      225 => :_storew,
      226 => :_storeb,
      227 => :_put_prop,
      228 => :_sread,
      229 => :_print_char,
      230 => :_print_num,
      231 => :_random,
      232 => :_push,
      233 => :_pull,
    }
  end

  ## Opcode implementations
  # 2op ################################

  #1
  # Jump if a is equal to any of the subsequent operands. (Thus @je a never jumps and @je a b jumps if a = b.)
  # je with just 1 operand is not permitted.
  #
  def _je # je a b ?(label)
    a, *b = @operands

    raise "je called with 1 operand" if b.empty?

    branch b.any? a
  end

  #2
  # Jump if a < b (using a signed 16-bit comparison).
  #
  def _jl # jl a b ?(label)
    a, b = @operands

    branch (sint16 a) < (sint16 b)
  end

  #3
  # Jump if a > b (using a signed 16-bit comparison).
  #
  def _jg # jg a b ?(label)
    a, b = @operands

    branch (sint16 a) > (sint16 b)
  end

  #4
  # Decrement variable, and branch if it is now less than the given value.
  #
  def _dec_chk # dec_chk (variable) value ?(label)
    var, val = @operands

    num = decrement var
    branch (sint16 num) < (sint16 val)
  end

  #5
  # Increment variable, and branch if now greater than value.
  #
  def _inc_chk # inc_chk (variable) value ?(label)
    var, val = @operands

    num = increment var
    branch (sint16 num) > (sint16 val)
  end

  #6
  # Jump if object a is a direct child of b, i.e., if parent of a is b.
  #
  def _jin # jin obj1 obj2 ?(label)
    a, b = @operands

    branch (zobj a).parent == b
  end

  #7
  # Jump if all of the flags in bitmap are set (i.e. if bitmap & flags == flags).
  #
  def _test # test bitmap flags ?(label)
    bitmap, flags = @operands

    branch ((bitmap & flags) == flags)
  end

  #8
  # Bitwise OR.
  #
  def _or # or a b -> (result)
    a, b = @operands
    var = read_byte

    store var, a | b
  end

  #9
  # Bitwise AND.
  #
  def _and # and a b -> (result)
    a, b = @operands
    var = read_byte

    store var, a & b
  end

  #10
  # Jump if object has attribute.
  #
  def _test_attr # test_attr object attribute ?(label)
    obj_id, attribute = @operands

    branch (zobj obj_id).has_attribute? attribute
  end

  #11
  # Make object have the attribute numbered attribute.
  #
  def _set_attr # set_attr object attribute
    obj_id, attribute = @operands

    (zobj obj_id).set_attribute attribute
  end

  #12
  # Make object not have the attribute numbered attribute.
  #
  def _clear_attr # clear_attr object attribute
    obj_id, attribute = @operands

    (zobj obj_id).clear_attribute attribute
  end

  #13
  # Set the VARiable referenced by the operand to value.
  #
  def _store # store (variable) value
    var, val = @operands

    if var == 0
      @stack[-1] = uint16 val
    else
      store var, val
    end
  end

  #14
  # Moves object O to become the first child of the destination object D. (Thus, after the operation the child of D is O, and the sibling of O is whatever was previously the child of D.) All children of O move with it. (Initially O can be at any point in the object tree; it may legally have parent zero.)
  #
  def _insert_obj # insert_obj object destination
    obj_id, dest_id = @operands

    object      = zobj obj_id
    dest_object = zobj dest_id

    object.remove # Take out of the tree
    object.parent  = dest_object.id
    object.sibling = dest_object.child

    dest_object.child = object.id
  end

  #15
  # Stores array-->word-index (i.e., the word at address array+2*word-index, which must lie in static or dynamic memory).
  #
  def _loadw # loadw array word-index -> (result)
    array, word_index = @operands
    var = read_byte

    word = peek_word array + 2 * word_index
    store var, word
  end

  #16
  # Stores array->byte-index (i.e., the byte at address array+byte-index, which must lie in static or dynamic memory).
  #
  def _loadb # loadb array byte-index -> (result)
    array, byte_index = @operands
    var = read_byte

    byte = peek_byte array + byte_index
    store var, byte # Does this store just a byte at the global addresses? Or store it like it's a word? AAAAAAAAAAAAAAAAA
  end

  #17
  # Read property from object (resulting in the default value if it had no such declared property). If the property has length 1, the value is only that byte. If it has length 2, the first two bytes of the property are taken as a word value. It is illegal for the opcode to be used if the property has length greater than 2, and the result is unspecified.
  #
  def _get_prop # get_prop object property -> (result)
    obj_id, prop_id = @operands
    var = read_byte

    addr, size = (zobj obj_id).property_or_default prop_id

    if addr
      case size
      when 1 then val = peek_byte addr
      when 2 then val = peek_word addr
      else raise "illegal prop size #{size}"
      end
    end

    store var, val
  end

  #18
  # Get the byte address (in dynamic memory) of the property data for the given object's property. This must return 0 if the object hasn't got the property.
  #
  def _get_prop_addr # get_prop_addr object property -> (result)
    obj_id, prop_id = @operands
    var = read_byte

    addr, size = (zobj obj_id).property prop_id

    store var, addr ? addr : 0
  end

  #19
  # Gives the number of the next property provided by the quoted object. This may be zero, indicating the end of the property list; if called with zero, it gives the first property number present. It is illegal to try to find the next property of a property which does not exist, and an interpreter should halt with an error message (if it can efficiently check this condition).
  #
  def _get_next_prop # get_next_prop object property -> (result)
    obj_id, prop_id = @operands
    var = read_byte

    if prop_id == 0
      property = (zobj obj_id).first_property
    else
      property = (zobj obj_id).property_after prop_id
    end

    store var, property
  end

  #20
  # Signed 16-bit addition.
  #
  def _add # add a b -> (result)
    a, b = @operands
    var = read_byte

    store var, (sint16 a) + (sint16 b)
  end

  #21
  # Signed 16-bit subtraction.
  #
  def _sub # sub a b -> (result)
    a, b = @operands
    var = read_byte

    store var, (sint16 a) - (sint16 b)
  end

  #22
  # Signed 16-bit multiplication.
  #
  def _mul # mul a b -> (result)
    a, b = @operands
    var = read_byte

    store var, (sint16 a) * (sint16 b)
  end

  #23
  # Signed 16-bit division. Division by zero should halt the interpreter with a suitable error message.
  #
  def _div # div a b -> (result)
    a, b = @operands
    var = read_byte

    raise 'divide by 0' if b == 0

    store var, ((sint16 a).idiv (sint16 b)) # integer division??
  end

  #24
  # Remainder after signed 16-bit division. Division by zero should halt the interpreter with a suitable error message.
  #
  def _mod # mod a b -> (result)
    a, b = @operands
    var = read_byte

    raise 'mod by 0' if b == 0

    a = sint16 a
    b = sint16 b

    store var, a - (b * (a / b).truncate)
  end

  # 1op ################################
  #128
  # Jump if a = 0.
  #
  def _jz # jz a ?(label)
    branch @operands[0] == 0
  end

  #129
  # Get next object in tree, branching if this exists, i.e. is not 0.
  #
  def _get_sibling # get_sibling object -> (result) ?(label)
    obj_id = @operands[0]
    var = read_byte

    sibling = (zobj obj_id).sibling
    store var, sibling
    branch sibling != 0
  end

  #130
  # Get first object contained in given object, branching if this exists, i.e. is not nothing (i.e., is not 0).
  #
  def _get_child # get_child object -> (result) ?(label)
    obj_id = @operands[0]
    var = read_byte

    child = (zobj obj_id).child
    store var, child
    branch child != 0
  end

  #131
  # Get parent object (note that this has no "branch if exists" clause).
  #
  def _get_parent # get_parent object -> (result)
    obj_id = @operands[0]
    var = read_byte

    parent = (zobj obj_id).parent
    store var, parent
  end

  #132
  # Get length of property data (in bytes) for the given object's property. It is illegal to try to find the property length of a property which does not exist for the given object, and an interpreter should halt with an error message (if it can efficiently check this condition).
  # @get_prop_len 0 must return 0. This is required by some Infocom games and files generated by old versions of Inform.
  #
  def _get_prop_len # get_prop_len property-address -> (result)
    property_address = @operands[0]
    var = read_byte

    if property_address == 0
      val = 0
    else
      val = peek_byte property_address - 1
      val = ((val >> 5) + 1)
    end

    store var, val
  end

  #133
  # Increment variable by 1. (This is signed, so -1 increments to 0.)
  #
  def _inc # inc (variable)
    var = @operands[0]

    increment var
  end

  #134
  # Decrement variable by 1. This is signed, so 0 decrements to -1.
  #
  def _dec # dec (variable)
    var = @operands[0]

    decrement var
  end

  #135
  # Print (Z-encoded) string at given byte address, in dynamic or static memory.
  #
  def _print_addr # print_addr byte-address-of-string
    addr = @operands[0]

    text = peek_zscii_text addr

    @screen.print text

    dbg :print { text }
  end

  #137
  # Detach the object from its parent, so that it no longer has any parent. (Its children remain in its possession.)
  #
  def _remove_obj # remove_obj object
    obj_id = @operands[0]

    (zobj obj_id).remove
  end

  #138
  # Print short name of object (the Z-encoded string in the object header, not a property). If the object number is invalid, the interpreter should halt with a suitable error message.
  #
  def _print_obj # print_obj object
    obj_id = @operands[0]

    text = parse_zchar_sequence peek_zchar_text (zobj obj_id).name_addr
    @screen.print text

    dbg :print { text }
  end

  #139
  # Returns from the current routine with the value given.
  #
  def _ret # ret value
    val = @operands[0]

    routine_return val
  end

  #140
  # Jump (unconditionally) to the given label. (This is not a branch instruction and the operand is a 2-byte signed offset to apply to the program counter.) It is legal for this to jump into a different routine (which should not change the routine call state), although it is considered bad practice to do so and the Txd disassembler is confused by it.
  # The destination of the jump opcode is: Address after instruction + Offset - 2
  # This is analogous to the calculation for branch offsets.
  #
  def _jump # jump ?(label)
    offset = sint16 @operands[0]

    jump @pc + offset - 2
  end

  #141
  # Print the (Z-encoded) string at the given packed address in high memory.
  #
  def _print_paddr # print_paddr packed-address-of-string
    byte = @operands[0]

    addr = (2 * byte)
    text = peek_zscii_text addr

    @screen.print text

    dbg :print { text }
  end

  #142
  # The value of the variable referred to by the operand is stored in the result. (Inform doesn't use this; see the notes to S 14.)
  #
  def _load # load (variable) -> (result)
    variable = @operands[0]
    var = read_byte

    if variable == 0
      store var, @stack.last
    else
      store var, (get_var variable)
    end
  end

  #143
  # Bitwise NOT (i.e., all 16 bits reversed). Note that in Versions 3 and 4 this is a 1OP instruction, reasonably since it has 1 operand, but in later Versions it was moved into the extended set to make room for call_1n.
  #
  def _not # not value -> (result)
    val = @operands[0]
    var = read_byte
    store var, ~val
  end

  # 0op ################################
  #176
  # Return true (i.e., 1) from the current routine.
  #
  def _rtrue # rtrue
    routine_return 1
  end

  #177
  # Return false (i.e., 0) from the current routine.
  #
  def _rfalse # rfalse
    routine_return 0
  end

  #178
  # Print the quoted (literal) Z-encoded string.
  #
  def _print # print (literal-string)
    text = read_zscii_text

    @screen.print text

    dbg :print { text }
  end

  #179
  # Print the quoted (literal) Z-encoded string, then print a new-line and then return true (i.e., 1).
  #
  def _print_ret # print_ret (literal-string)
    text = read_zscii_text

    @screen.println text

    routine_return 1
  end

  #181
  # On Versions 3 and 4, attempts to save the game (all questions about filenames are asked by interpreters) and branches if successful. From Version 5 it is a store rather than a branch instruction; the store value is 0 for failure, 1 for "save succeeded" and 2 for "the game is being restored and is resuming execution again from here, the point where it was saved".
  # It is illegal to use this opcode within an interrupt routine (one called asynchronously by a sound effect, or keyboard timing, or newline counting).
  # ***[1.0] The extension also has (optional) parameters, which save a region of the save area, whose address and length are in bytes, and provides a suggested filename: name is a pointer to an array of ASCII characters giving this name (as usual preceded by a byte giving the number of characters). See S 7.6. (Whether Infocom intended these options as part of Version 5 is doubtful, but it's too useful a feature to exclude from this Standard.)
  # ***[1.1] As of Standard 1.1 an additional optional parameter, prompt, is allowed on Version 5 extended save/restore. This allows a game author to tell the interpreter whether it should ask for confirmation of the provided file name (prompt is 1), or just silently save/restore using the provided filename (prompt is 0). If the parameter is not provided, whether to prompt or not is a matter for the interpreter - this might be globally user-configurable. Infocom's interpreters do prompt for filenames, many modern ones do not.
  #
  def _save # save ?(label)
    # NOTE:: lol, this isn't how you should save but easier

    $args.state.data.pc = @pc
    $gtk.serialize_state 'app/save.txt', $args.state.data
    $gtk.write_file 'app/save.data', @memory.pack("C*")
    @screen.println 'Game Saved'

    branch 1
  end

  #182
  # See save. In Version 3, the branch is never actually made, since either the game has successfully picked up again from where it was saved, or it failed to load the save game file.
  # As with restart, the transcription and fixed font bits survive. The interpreter gives the game a way of knowing that a restore has just happened (see save).
  # ***[1.0] From Version 5 it can have optional parameters as save does, and returns the number of bytes loaded if so. (Whether Infocom intended these options as part of Version 5 is doubtful, but it's too useful a feature to exclude from this Standard.)
  # If the restore fails, 0 is returned, but once again this necessarily happens since otherwise control is already elsewhere.
  #
  def _restore # restore ?(label)
    pc = @pc

    $state.data = $gtk.deserialize_state 'app/save.txt'
    @pc = $state.data.pc

    data = $gtk.read_file 'app/save.data'
    if data
      @memory = data.bytes
      @screen.println 'Game Restored'
      success = 1
    else
      @pc = pc
      $gtk.notify_subdued! 

      @screen.println 'Restore Failed'
      success = 0
    end

    branch success
  end

  #184
  # Pops top of stack and returns that. (This is equivalent to ret sp, but is one byte cheaper.)
  #
  def _ret_popped # ret_popped
    val = @stack.pop

    routine_return val
  end

  #185
  # Throws away the top item on the stack. (This was useful to lose unwanted routine call results in early Versions.)
  #
  def _pop # pop
    @stack.pop
  end

  #186
  # Exit the game immediately. (Any "Are you sure?" question must be asked by the game, not the interpreter.) It is not legal to return from the main routine (that is, from where execution first begins) and this must be used instead.
  #
  def _quit # quit
    :quit
  end

  #187
  # Print carriage return
  #
  def _new_line # new_line
    @screen.ret
  end

  #188
  # (In Version 3 only.) Display and update the status line now (don't wait until the next keyboard input). (In theory this opcode is illegal in later Versions but an interpreter should treat it as nop, because Version 5 Release 23 of 'Wishbringer' contains this opcode by accident.)
  #
  def _show_status # show_status
    @screen.set_status_line *status_line_values
  end

  #189
  # Verification counts a (two byte, unsigned) checksum of the file from $0040 onwards (by taking the sum of the values of each byte in the file, modulo $10000) and compares this against the value in the game header, branching if the two values agree. (Early Version 3 games do not have the necessary checksums to make this possible.)
  # The interpreter must stop calculating when the file length (as given in the header) is reached. It is legal for the file to contain more bytes than this, but if so the extra bytes should all be 0. (Some story files are padded out to an exact number of virtual-memory pages.) However, many Infocom story files in fact contain non-zero data in the padding, so interpreters must be sure to exclude the padding from checksum calculations.
  # 11.1.6 The file length stored at $1a is actually divided by a constant, depending on the Version, to make it fit into a header word. This constant is 2 for Versions 1 to 3, 4 for Versions 4 to 5 or 8 for Versions 6 and later.
  #
  def _verify # verify ?(label)
    file     = $gtk.read_file(@file_name).bytes
    checksum = (file[0x0040, (2 * @header.file_length) - 0x0040].reduce(0, :+)) % 0x10000

    branch @header.checksum == checksum
  end

  # VAR ################################
  #224
  # The only call instruction in Version 3, Inform reads this as call_vs in higher versions: it calls the routine with 0, 1, 2 or 3 arguments as supplied and stores the resulting return value. (When the address 0 is called as a routine, nothing happens and the return value is false.)
  #
  def _call # call routine ...0 to 3 args... -> (result)
    var = read_byte

    routine var
  end

  #225
  # array-->word-index = value, i.e. stores the given value in the word at address array+2*word-index (which must lie in dynamic memory). (See loadw.)
  #
  def _storew # storew array word-index value
    array, word_index, value = @operands

    write_word array + 2 * word_index, value
  end

  #226
  # array->byte-index = value, i.e. stores the given value in the byte at address array+byte-index (which must lie in dynamic memory). (See loadb.)
  #
  def _storeb # storeb array byte-index value
    array, byte_index, value = @operands

    write_byte array + byte_index, value
  end

  #227
  # Writes the given value to the given property of the given object. If the property does not exist for that object, the interpreter should halt with a suitable error message. If the property length is 1, then the interpreter should store only the least significant byte of the value. (For instance, storing -1 into a 1-byte property results in the property value 255.) As with get_prop the property length must not be more than 2: if it is, the behaviour of the opcode is undefined.
  #
  def _put_prop # put_prop object property value
    obj_id, prop_id, value = @operands

    addr, size = (zobj obj_id).property prop_id
    raise "no property #{prop_id} for obj #{obj_id}" if addr.nil?
    case size
    when 1 then write_byte addr, (uint8 value)
    when 2 then write_word addr, value
    else raise "put_prop size #{size}"
    end
  end

  #228
  # This is the Inform name for the keyboard-reading opcode under Versions 3 and 4. (Inform calls the same opcode aread in later Versions.) See read for the specification.
  #
  # (Note that Inform internally names the read opcode as aread in Versions 5 and later and sread in Versions 3 and 4.)
  #
  # This opcode reads a whole command from the keyboard (no prompt is automatically displayed). It is legal for this to be called with the cursor at any position on any window.
  #
  # In Versions 1 to 3, the status line is automatically redisplayed first.
  #
  # A sequence of characters is read in from the current input stream until a carriage return (or, in Versions 5 and later, any terminating character) is found.
  #
  # In Versions 1 to 4, byte 0 of the text-buffer should initially contain the maximum number of letters which can be typed, minus 1 (the interpreter should not accept more than this). The text typed is reduced to lower case (so that it can tidily be printed back by the program if need be) and stored in bytes 1 onward, with a zero terminator (but without any other terminator, such as a carriage return code). (This means that if byte 0 contains n then the buffer must contain n+1 bytes, which makes it a string array of length n in Inform terminology.)
  #
  # In Versions 5 and later, byte 0 of the text-buffer should initially contain the maximum number of letters which can be typed (the interpreter should not accept more than this). The interpreter stores the number of characters actually typed in byte 1 (not counting the terminating character), and the characters themselves (reduced to lower case) in bytes 2 onward (not storing the terminating character). (Some interpreters wrongly add a zero byte after the text anyway, so it is wise for the buffer to contain at least n+3 bytes.)
  #
  # Moreover, if byte 1 contains a positive value at the start of the input, then read assumes that number of characters are left over from an interrupted previous input, and writes the new characters after those already there. Note that the interpreter does not redisplay the characters left over: the game does this, if it wants to. This is unfortunate for any interpreter wanting to give input text a distinctive appearance on-screen, but 'Beyond Zork', 'Zork Zero' and 'Shogun' clearly require it. ("Just a tremendous pain in my butt" -- Andrew Plotkin; "the most unfortunate feature of the Z-machine design" -- Stefan Jokisch.)
  #
  # In Version 4 and later, if the operands time and routine are supplied (and non-zero) then the routine call routine() is made every time/10 seconds during the keyboard-reading process. If this routine returns true, all input is erased (to zero) and the reading process is terminated at once. (The terminating character code is 0.) The routine is permitted to print to the screen even if it returns false to signal "carry on": the interpreter should notice and redraw the input line so far, before input continues. (Frotz notices by looking to see if the cursor position is at the left-hand margin after the interrupt routine has returned.)
  #
  # If input was terminated in the usual way, by the player typing a carriage return, then a carriage return is printed (so the cursor moves to the next line). If it was interrupted, the cursor is left at the rightmost end of the text typed in so far.
  #
  # Next, lexical analysis is performed on the text (except that in Versions 5 and later, if parse-buffer is zero then this is omitted). Initially, byte 0 of the parse-buffer should hold the maximum number of textual words which can be parsed. (If this is n, the buffer must be at least 2 + 4*n bytes long to hold the results of the analysis.)
  #
  # The interpreter divides the text into words and looks them up in the dictionary, as described in S 13. The number of words is written in byte 1 and one 4-byte block is written for each word, from byte 2 onwards (except that it should stop before going beyond the maximum number of words specified). Each block consists of the byte address of the word in the dictionary, if it is in the dictionary, or 0 if it isn't; followed by a byte giving the number of letters in the word; and finally a byte giving the position in the text-buffer of the first letter of the word.
  #
  # In Version 5 and later, this is a store instruction: the return value is the terminating character (note that the user pressing his "enter" key may cause either 10 or 13 to be returned; the interpreter must return 13). A timed-out input returns 0.
  #
  # (Versions 1 and 2 and early Version 3 games mistakenly write the parse buffer length 240 into byte 0 of the parse buffer: later games fix this bug and write 59, because 2+4*59 = 238 so that 59 is the maximum number of textual words which can be parsed into a buffer of length 240 bytes. Old versions of the Inform 5 library commit the same error. Neither mistake has very serious consequences.)
  #
  # (Interpreters are asked to halt with a suitable error message if the text or parse buffers have length of less than 3 or 6 bytes, respectively: this sometimes occurs due to a previous array being overrun, causing bugs which are very difficult to find.)
  #
  def _sread # sread text parse
    text_buffer, parse_buffer = @operands
    max_letters = peek_byte text_buffer
    max_words = peek_byte parse_buffer
    buffer_length = 2 + 4 * max_words

    # byte 0: max_leters
    # byte 1: n typed chars
    # byte
    # terminator: 0

    @screen.set_status_line *status_line_values
    input = (@screen.prompt_input max_letters).downcase
    @screen.ret

    (input.bytes + [0]).each_with_index { |byte, i| write_byte (text_buffer + 1 + i), byte }

    blocks = lexical_analysis input

    write_byte parse_buffer + 1, blocks.length
    blocks.each_with_index do |(word, byte_3, byte_4), i|
      addr = parse_buffer + 2 + 4 * i
      write_word addr, word
      write_byte addr + 2, byte_3
      write_byte addr + 3, byte_4
    end
  end

  #229
  # Print a ZSCII character. The operand must be a character code defined in ZSCII for output (see S 3). In particular, it must certainly not be negative or larger than 1023.
  #
  def _print_char # print_char output-character-code
    zscii_code = @operands[0]

    raise "print_char: #{zscii_code}" if zscii_code < 0 || zscii_code > 1023

    text = zscii_to_ascii zscii_code
    @screen.print text

    dbg :print { text }
  end

  #230
  # Print (signed) number in decimal.
  #
  def _print_num # print_num value
    text = @operands[0]

    @screen.print text.to_s

    dbg :print { text }
  end

  #231
  # If range is positive, returns a uniformly random number between 1 and range. If range is negative, the random number generator is seeded to that value and the return value is 0. Most interpreters consider giving 0 as range illegal (because they attempt a division with remainder by the range), but correct behaviour is to reseed the generator in as random a way as the interpreter can (e.g. by using the time in milliseconds).
  # (Some version 3 games, such as 'Enchanter' release 29, had a debugging verb #random such that typing, say, #random 14 caused a call of random with -14.)
  #
  def _random # random range -> (result)
    range = sint16 @operands[0]
    var = read_byte

    if range > 0
      val = 1 + (range.randomize :int)
      store var, val
    elsif range == 0
      val = 0
      srand Time.now.to_i
      store var, val # store 0? unclear
    else
      val = 0
      srand range
      store var, val
    end
  end

  #232
  # Pushes value onto the game stack.
  #
  def _push # push value
    val = @operands[0]

    store 0x00, val
  end

  #233
  # Pulls value off a stack. (If the stack underflows, the interpreter should halt with a suitable error message.) In Version 6, the stack in question may be specified as a user one: otherwise it is the game stack.
  #
  def _pull # pull (variable)
    var = @operands[0]
    val = @stack.pop

    if var == 0
      @stack[-1] = uint16 val
    else
      store var, val
    end
  end
end
