# frozen_string_literal: true

require "test_helper"

# The test label is the one document Bellhop itself produces, and the only
# feedback anyone gets from it is whether something legible came out of the
# printer. What it must not do is depend on the width of the stock.
class TestLabelTest < ActiveSupport::TestCase
  test "the default label anchors to the top left and never asks how wide the stock is" do
    zpl = Bellhop.test_label

    assert_match(/\A\^XA\n/, zpl)
    assert_match(/\^XZ\z/, zpl)
    assert_includes zpl, Bellhop::TEST_LABEL_LOGO
    assert_includes zpl, "Bellhop."
    assert_includes zpl, "Test Label Print"

    # No field block, so nothing is positioned against a width that was guessed.
    refute_includes zpl, "^FB"

    # And none of the commands that can wedge a printer's firmware.
    refute_includes zpl, "^PW"
    refute_includes zpl, "^LL"
    refute_includes zpl, "^CI"
    refute_includes zpl, "^GB"
  end

  # 1.25in at 203 dpi is 254 dots, the narrowest stock a desk is likely to hold.
  # The wordmark starts 72 dots in, after the mark, and its type measures about
  # 160 dots, so the line ends near dot 233 and has to stay inside that.
  test "the default label starts near enough the left edge to fit narrow stock" do
    origins = Bellhop.test_label.scan(/\^FO(\d+),(\d+)/).map { |x, y| [ x.to_i, y.to_i ] }

    assert_equal 3, origins.size
    assert(origins.all? { |x, _| x <= 72 }, "left origin leaves too little width")
    assert(origins.all? { |_, y| y <= 100 }, "top origin sits too far down a short label")
  end

  test "a known width centres across it instead" do
    zpl = Bellhop.test_label(width: 812)

    # The lockup is 218 dots wide, so on 812 the mark's origin sits at 297 and
    # the wordmark 52 dots after it. `^FB` cannot centre a `^GF` graphic.
    assert_includes zpl, "^FO297,22"
    assert_includes zpl, "^FO349,40"
    assert_includes zpl, "^FB812,2,0,C,0"
    refute_includes zpl, "^FB812,1"
  end

  test "a width given as a string is still a number of dots" do
    assert_includes Bellhop.test_label(width: "406"), "^FB406,"
  end
end
