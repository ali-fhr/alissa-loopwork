# frozen_string_literal: true

require "minitest/autorun"
require "adder"

class TestAdder < Minitest::Test
  def test_adds
    assert_equal 5, Adder.add(2, 3)
  end
end
