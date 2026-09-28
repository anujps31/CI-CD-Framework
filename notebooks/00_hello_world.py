# Databricks notebook source
# Hello-world smoke test for Databricks + Unity Catalog + ADLS.
# Reads the file the pipeline's ADLS smoke test just wrote, saves it as a Unity Catalog
# table, and returns what it read so the pipeline can check it end to end.
import json

from pyspark.sql.functions import current_timestamp

dbutils.widgets.text("catalog", "dataplatform_dev")
dbutils.widgets.text("storage_account", "stdataplatformsyrendev01")
catalog = dbutils.widgets.get("catalog")
storage_account = dbutils.widgets.get("storage_account")

# COMMAND ----------

# Read through the Unity Catalog external location (storage credential + access connector).
source = f"abfss://raw@{storage_account}.dfs.core.windows.net/landing/hello/hello.csv"
df = spark.read.option("header", "true").csv(source)
row = df.first()
if row is None or row["message"] != "Hello World":
    raise ValueError(f"Unexpected content in {source}: {row}")

# COMMAND ----------

# Write a managed Unity Catalog table and read it back.
table = f"{catalog}.raw.hello_world"
df.withColumn("loaded_at", current_timestamp()).write.mode("overwrite").saveAsTable(table)
rows = spark.table(table).count()
print(f"{row['message']} from build {row['build_id']} -> {table} ({rows} row)")

# COMMAND ----------

dbutils.notebook.exit(json.dumps({"message": row["message"], "build_id": row["build_id"], "table": table, "rows": rows}))