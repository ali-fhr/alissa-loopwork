package smoke

import org.apache.spark.sql.{Dataset, SparkSession}

object WordCount {
  /** Counts words across lines, most frequent first (ties by word). */
  def count(spark: SparkSession, lines: Seq[String]): Seq[(String, Long)] = {
    import spark.implicits._
    val words: Dataset[String] =
      lines.toDS().flatMap(_.split("\\s+")).filter(_.nonEmpty)
    words.groupByKey(identity).count().collect().toSeq
      .sortBy { case (w, n) => (-n, w) }
  }
}
