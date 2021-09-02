# The object table
# https://inform-fiction.org/zmachine/standards/z1point1/sect12.html

class ZObject
  attr_reader :id

  def initialize zmachine, obj_id
    @zm = zmachine
    @id = obj_id
  end

  def zobj obj_id
    self.class.new @zm, obj_id
  end

  def addr
    (@zm.header.object_table_addr + 62) + 9 * (@id - 1)
  end

  def has_attribute? attribute
    byte_addr = addr + (attribute.idiv 8)
    (@zm.peek_byte(byte_addr) & (0x80 >> (attribute & 7))) > 0
  end

  def set_attribute attribute
    byte_addr = addr + (attribute.idiv 8)
    byte = ((@zm.peek_byte byte_addr) | (0x80 >> (attribute & 7)))
    @zm.write_byte byte_addr, byte
  end

  def clear_attribute attribute
    byte_addr = addr + (attribute.idiv 8)
    byte = ((@zm.peek_byte byte_addr) & (~(0x80 >> (attribute & 7))))
    @zm.write_byte byte_addr, byte
  end

  def parent
    @zm.peek_byte addr + 4
  end

  def parent= id
    @zm.write_byte addr + 4, id
  end

  def clear_parent
    self.parent = 0
  end

  def parent?
    parent > 0
  end

  def sibling
    @zm.peek_byte addr + 5
  end

  def sibling= id
    @zm.write_byte addr + 5, id
  end

  def clear_sibling
    self.sibling = 0
  end

  def sibling?
    sibling > 0
  end

  def child
    @zm.peek_byte addr + 6
  end

  def child= id
    @zm.write_byte addr + 6, id
  end

  def clear_child
    self.child = 0
  end

  def child?
    child > 0
  end

  def properties
    @zm.peek_word addr + 7
  end

  def properties_text_length
    @zm.peek_byte properties
  end

  def properties_list
    properties + (properties_text_length * 2) + 1
  end

  def name_addr
    properties + 1
  end

  def properties_enum
    Enumerator.new do |yielder|
      ptr = properties_list
      loop do
        size_byte = @zm.peek_byte ptr
        break if size_byte == 0

        prop_id  = size_byte & 0x1f
        size     = (size_byte >> 5) + 1

        yielder << [prop_id, ptr + 1, size]

        ptr += size + 1
      end
    end
  end

  def property prop_id
    properties_enum.each { |num, *rest| return rest if prop_id == num }

    nil
  end

  # like #property, but returns default if not found
  def property_or_default prop_id
    address, size = property prop_id
    unless address
      address, size = @zm.header.object_table_addr + 2 * (prop_id - 1), 2
    end

    return address, size
  end

  def first_property
    result = properties_enum.take(1)
    result.empty? ? 0 : result[0][0]
  end

  def property_after prop_id
    properties_enum.each_cons(2) { |a, b| return b[0] if prop_id == a[0] }

    0
  end

  ##
  # Object Tree : Note 'Tree'
  # [ 41]
  #   |
  # [ 68]
  #   |
  # [ 21] - [239] - [127]
  #           |
  #         [ 80]
  #
  # If I move object [239] to be a sibling of [ 68]
  # [ 21]'s sibling becomes [127]
  # [239]'s parent becomes [ 41]
  # [239]'s sibling is nil
  #
  # [ 41]
  #   |
  # [ 68] - [239]
  #   |       |
  #   |     [ 80]
  #   |
  # [ 21] - [127]
  #
  def remove
    return unless parent? # No need to remove if parentless

    parent_obj  = zobj self.parent
    sibling_obj = zobj self.sibling

    clear_parent
    clear_sibling

    if parent_obj.child == self.id # Am I my parent's child?
      parent_obj.child = sibling_obj.id
    else
      child_obj = zobj parent_obj.child
      while self.id != child_obj.sibling # Next Child!
        raise "malformed object tree" if child_obj.sibling == 0
        child_obj = zobj child_obj.sibling
      end
      child_obj.sibling = sibling_obj.id
    end
  end
end
