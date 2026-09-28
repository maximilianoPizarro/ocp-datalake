"""Spark Structured Streaming: Kafka churn-events -> /predict.

Reads JSON messages from Streams for Apache Kafka (plain listener),
POSTs each row to the in-cluster inference gateway. Expected for the
demo payload: churn true, probability ~0.5987.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from pyspark.sql import SparkSession

BOOTSTRAP = os.environ.get(
    "KAFKA_BOOTSTRAP",
    "churn-kafka-bootstrap.kafka.svc:9092",
)
TOPIC = os.environ.get("KAFKA_TOPIC", "churn-events")
PREDICT_URL = os.environ.get(
    "PREDICT_URL",
    "http://inference.ocp-datalake.svc:4180/predict",
)


def predict(body: dict) -> None:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        PREDICT_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
            print(f"PREDICT_HTTP={resp.status}", flush=True)
            print(f"PREDICT_RESPONSE={payload}", flush=True)
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        print(f"PREDICT_HTTP={exc.code}", flush=True)
        print(f"PREDICT_RESPONSE={err}", flush=True)
        raise


def score_batch(batch_df, batch_id: int) -> None:
    rows = batch_df.collect()
    print(f"BATCH_ID={batch_id} rows={len(rows)}", flush=True)
    for row in rows:
        raw = row["json"]
        print(f"KAFKA_MESSAGE={raw}", flush=True)
        body = json.loads(raw)
        predict(
            {
                "tenure": int(body["tenure"]),
                "charges": float(body["charges"]),
                "support_tickets": int(body["support_tickets"]),
            }
        )


def main() -> None:
    spark = SparkSession.builder.appName("spark-from-kafka-churn").getOrCreate()
    print(f"SPARK_VERSION={spark.version}", flush=True)
    print(f"KAFKA_BOOTSTRAP={BOOTSTRAP}", flush=True)
    print(f"KAFKA_TOPIC={TOPIC}", flush=True)

    stream = (
        spark.readStream.format("kafka")
        .option("kafka.bootstrap.servers", BOOTSTRAP)
        .option("subscribe", TOPIC)
        .option("startingOffsets", "earliest")
        .load()
        .selectExpr("CAST(value AS STRING) AS json")
    )

    query = (
        stream.writeStream.foreachBatch(score_batch)
        .option("checkpointLocation", "/tmp/spark-kafka-churn-checkpoint")
        .start()
    )
    query.awaitTermination()


if __name__ == "__main__":
    main()
