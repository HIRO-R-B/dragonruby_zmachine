# How text and characters are encoded
# https://inform-fiction.org/zmachine/standards/z1point1/sect03.html

# The dictionary and lexical analysis
# https://inform-fiction.org/zmachine/standards/z1point1/sect13.html

# NOTE:: I will state ahead of time, these methods are named poorly :(

module ZText
  UNICODE = {
    155 => 'ae', 156 => 'oe', 157 => 'ue', 158 => 'Ae', 159 => 'Oe',
    160 => 'Ue', 161 => 'ss', 162 => '"',  163 => '"',  164 => 'e',
    165 => 'i',  166 => 'y',  167 => 'E',  168 => 'I',  169 => 'a',
    170 => 'e',  171 => 'i',  172 => 'o',  173 => 'u',  174 => 'y',
    175 => 'A',  176 => 'E',  177 => 'I',  178 => 'O',  179 => 'U',
    180 => 'Y',  181 => 'a',  182 => 'e',  183 => 'i',  184 => 'o',
    185 => 'u',  186 => 'A',  187 => 'E',  188 => 'I',  189 => 'O',
    190 => 'U',  191 => 'a',  192 => 'e',  193 => 'i',  194 => 'o',
    195 => 'u',  196 => 'A',  197 => 'E',  198 => 'I',  199 => 'O',
    200 => 'U',  201 => 'a',  202 => 'A',  203 => 'o',  204 => 'O',
    205 => 'a',  206 => 'n',  207 => 'o',  208 => 'A',  209 => 'N',
    210 => 'O',  211 => 'ae', 212 => 'AE', 213 => 'c',  214 => 'C',
    215 => 'th', 216 => 'th', 217 => 'Th', 218 => 'Th', 219 => 'L',
    220 => 'oe', 221 => 'OE', 222 => '!',  223 => '?' }

  A0 = 'abcdefghijklmnopqrstuvwxyz'
  A1 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  A2 = " \n0123456789.,!?_#'\"/\\-:()"

  def read_zscii_text
    zeq  = read_zchar_text
    text = parse_zchar_sequence zeq

    text
  end

  def peek_zscii_text addr
    zeq  = peek_zchar_text addr
    text = parse_zchar_sequence zeq

    text
  end

  def read_zchar_text
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

  def peek_zchar_text addr
    pc = @pc
    jump addr
    zseq = read_zchar_text
    jump pc

    zseq
  end

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
          zc = ((zchar_2 << 5) | zchar_3)
          result << zscii_to_ascii(zc)
        else
          result.push zchar_to_zscii zchar_1, (zchar == 4 ? A1 : A2)
        end
      else
        result << (zchar_to_zscii zchar, A0)
      end
    end

    result.flatten.join
  end

  # 0	       null                Output
  # 1-7      ----
  # 8        delete              Input
  # 9	       tab (V6)            Output
  # 10	     ----
  # 11	     sentence space (V6) Output
  # 12	     ----
  # 13	     newline             Input/Output
  # 14-26	   ----
  # 27	     escape              Input
  # 28-31	   ----
  # 32-126	 standard ASCII      Input/Output
  # 127-128	 ----
  # 129-132	 cursor u/d/l/r	     Input
  # 133-144	 fn keys f1 to f12   Input
  # 145-154	 keypad 0 to 9       Input
  # 155-251	 extra characters    Input/Output
  # 252	     menu click (V6)     Input
  # 253	     double-click (V6)   Input
  # 254	     single-click        Input
  # 255-1023 ----

  def zscii_to_ascii code
    case code
    when 0 # null? Just does nothing
      ''
    when 13
      "\n"
    when 32..126
      code.chr
    when 155..223
      UNICODE[code]
    else # TODO:: The rest lol, this should be enough for Zork though
      '?'
    end
  end

  def zchar_to_zscii zchar, alphabet
    alphabet[zchar - 6]
  end

  def get_abbreviation zchar_1, zchar_2
    idx = 32 * (zchar_1 - 1) + zchar_2
    addr = peek_word @header.abbr_table_addr + idx * 2
    zeq = peek_zchar_text addr * 2
  end

  def zchar_encode_char ascii_char
    idx = A0.index ascii_char
    return idx + 6 if idx
    idx = A2.index ascii_char
    return [5, idx + 6] if idx
    [5, 6, (ascii_char.ord >> 5), (ascii_char.ord & 0x1f)]
  end

  def zchar_encode ascii_text
    ascii_text.each_char.map { |char| zchar_encode_char char }.flatten
  end

  def zeq_to_zscii_text zeq
    result = zeq.each_slice(3).to_a

    last = result.length

    result.map_with_index do |(z1, z2, z3), i|
      bit = i == last - 1 ? 1 : 0
      form_zscii_text bit, z1, z2, z3
    end
  end

  def form_zscii_text bit, zchar_1, zchar_2, zchar_3
    zchar_2 ||= 5
    zchar_3 ||= 5

    (bit << 15) | (zchar_1 << 10) | (zchar_2 << 5) | zchar_3
  end

  # Sooo, parse buffer block:
  #  byte_1 & byte_2  byte_3               byte_4
  # (byte_addr || 0)  num_letters_in_word  addr_of_first_letter_of_word
  def lexical_analysis input
    word_seps, entry_len, num_entries, word_entries_addr = dict_info

    words = dict_split input, word_seps

    zeqs = words.map { |word, _| zchar_encode word }

    encoded_texts = zeqs
                      .map { |zeq| dict_form zeq }
                      .map { |zeq| zeq_to_zscii_text zeq } # 2 word arrays

    matches = encoded_texts.map do |text|
      dict_lookup word_entries_addr, entry_len, num_entries, text
    end

    matches.zip(words.map { |_, *rest| rest }).map(&:flatten)
  end

  def dict_info
    pc = jump @header.dict_addr

    n           = read_byte
    word_seps   = n.times.map { |i| zscii_to_ascii read_byte }
    entry_len   = read_byte
    num_entries = read_word
    word_entries_addr = @pc
    jump pc

    [word_seps, entry_len, num_entries, word_entries_addr]
  end

  def dict_split input, word_seps
    output = []

    word       = ''
    word_start = true
    idx        = 0

    input.each_char.with_index do |char, i|
      if word_seps.any? char
        if !word.empty?
          output << [word, word.length, idx + 1]
          word = ''
          word_start = true
        end
        output << [char, i, 1]
      elsif char == ' '
        if !word.empty?
          output << [word, word.length, idx + 1]
          word = ''
          word_start = true
        end
      else
        if word_start
          word_start = false
          idx = i
        end
        word << char
      end
    end

    output << [word, word.length, idx + 1] unless word.empty?

    output
  end

  def dict_form zeq
    zeq << 5 while zeq.length < 6
    zeq[0..5]
  end

  def dict_lookup word_entries_addr, entry_len, num_entries, encoded_text
    word_1, word_2 = encoded_text

    num_entries.times do |i|
      addr = word_entries_addr + entry_len * i
      w1 = peek_word addr
      w2 = peek_word addr + 2

      if word_1 == w1 && word_2 == w2
        return addr
      end
    end

    0
  end
end
