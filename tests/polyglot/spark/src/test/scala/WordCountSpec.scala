package smoke

import org.apache.spark.sql.SparkSession
import org.scalatest.funsuite.AnyFunSuite

class WordCountSpec extends AnyFunSuite {
  test("word count in Spark local mode") {
    val spark = SparkSession.builder()
      .appName("polyglot-smoke")
      .master("local[1]")
      .config("spark.ui.enabled", "false")
      .config("spark.driver.host", "127.0.0.1")
      .config("spark.driver.bindAddress", "127.0.0.1")
      .config("spark.sql.shuffle.partitions", "1")
      .getOrCreate()
    try {
      val counts = WordCount.count(spark, Seq("to be or", "not to be", "be"))
      assert(counts == Seq("be" -> 3L, "to" -> 2L, "not" -> 1L, "or" -> 1L))
    } finally spark.stop()
  }
}
