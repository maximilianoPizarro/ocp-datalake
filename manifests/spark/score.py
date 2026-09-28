"""Spark batch row -> churn-score /predict.

Creates a one-row DataFrame shaped like an enterprise batch record, renames
feature columns with a Spark select, then POSTs the mapped body to the
in-cluster inference gateway. Expected: churn true, probability ~0.5987.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

PREDICT_URL = "http://inference.ocp-datalake.svc:4180/predict"


def main() -> None:
    spark = SparkSession.builder.appName("spark-to-churn-score").getOrCreate()
    print(f"SPARK_VERSION={spark.version}", flush=True)

    rows = [
        ("C-1001", "spark-batch", 12, 70.0, 3),
    ]
    df = spark.createDataFrame(
        rows,
        [
            "customer_id",
            "source",
            "account_tenure_months",
            "monthly_charges",
            "open_support_tickets",
        ],
    )
    mapped = df.select(
        F.col("account_tenure_months").alias("tenure"),
        F.col("monthly_charges").alias("charges"),
        F.col("open_support_tickets").alias("support_tickets"),
    )
    mapped.show(truncate=False)

    for row in mapped.collect():
        body = {
            "tenure": int(row["tenure"]),
            "charges": float(row["charges"]),
            "support_tickets": int(row["support_tickets"]),
        }
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

    # SPARK_HOLD_SECONDS keeps the driver and executor Running after the score
    # so a console capture can show the pods. Default 0 exits immediately.
    hold = int(os.environ.get("SPARK_HOLD_SECONDS", "0") or "0")
    if hold > 0:
        print(f"SPARK_HOLD_SECONDS={hold}", flush=True)
        time.sleep(hold)

    spark.stop()


if __name__ == "__main__":
    main()
