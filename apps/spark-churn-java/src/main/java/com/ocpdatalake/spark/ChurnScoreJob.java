package com.ocpdatalake.spark;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Collections;
import java.util.List;
import org.apache.spark.sql.Dataset;
import org.apache.spark.sql.Row;
import org.apache.spark.sql.RowFactory;
import org.apache.spark.sql.SparkSession;
import org.apache.spark.sql.types.DataTypes;
import org.apache.spark.sql.types.StructField;
import org.apache.spark.sql.types.StructType;

/**
 * Batch parity with manifests/spark/score.py: one enterprise-shaped row, Spark
 * column rename, POST to in-cluster /predict. Expected: churn true ~0.5987.
 */
public final class ChurnScoreJob {

  private ChurnScoreJob() {}

  public static void main(String[] args) throws Exception {
    String predictUrl =
        System.getenv().getOrDefault("PREDICT_URL", "http://inference.ocp-datalake.svc:4180/predict");

    SparkSession spark =
        SparkSession.builder().appName("spark-java-churn-score").getOrCreate();
    System.out.println("SPARK_VERSION=" + spark.version());

    StructType schema =
        new StructType(
            new StructField[] {
              DataTypes.createStructField("customer_id", DataTypes.StringType, false),
              DataTypes.createStructField("source", DataTypes.StringType, false),
              DataTypes.createStructField("account_tenure_months", DataTypes.IntegerType, false),
              DataTypes.createStructField("monthly_charges", DataTypes.DoubleType, false),
              DataTypes.createStructField("open_support_tickets", DataTypes.IntegerType, false),
            });

    List<Row> rows =
        Collections.singletonList(RowFactory.create("C-1001", "spark-java-batch", 12, 70.0, 3));
    Dataset<Row> df = spark.createDataFrame(rows, schema);
    Dataset<Row> mapped =
        df.selectExpr(
            "account_tenure_months as tenure",
            "monthly_charges as charges",
            "open_support_tickets as support_tickets");
    mapped.show(false);

    HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();

    for (Row row : mapped.collectAsList()) {
      int tenure = row.getAs("tenure");
      double charges = row.getAs("charges");
      int supportTickets = row.getAs("support_tickets");
      String body =
          String.format(
              "{\"tenure\":%d,\"charges\":%s,\"support_tickets\":%d}",
              tenure, Double.toString(charges), supportTickets);

      HttpRequest request =
          HttpRequest.newBuilder()
              .uri(URI.create(predictUrl))
              .timeout(Duration.ofSeconds(30))
              .header("Content-Type", "application/json")
              .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
              .build();

      HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
      System.out.println("PREDICT_HTTP=" + response.statusCode());
      System.out.println("PREDICT_RESPONSE=" + response.body());
      if (response.statusCode() < 200 || response.statusCode() >= 300) {
        throw new IllegalStateException("predict failed with HTTP " + response.statusCode());
      }
    }

    spark.stop();
  }
}
