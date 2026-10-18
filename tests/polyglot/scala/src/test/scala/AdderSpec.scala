package smoke

import org.scalatest.funsuite.AnyFunSuite

class AdderSpec extends AnyFunSuite:
  test("adds two ints") {
    assert(Adder.add(2, 3) == 5)
  }
