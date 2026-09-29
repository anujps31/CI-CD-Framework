# Databricks notebook source
# Ingest landing files from the raw container into the governed table <catalog>.raw.ingestion.
# Defaults read the hello-world file the pipeline writes, so the job runs out of the box.
# Point source_path and source_format at the project's real landing zone for real data.
from pyspark.sql.functions import col, current_timestamp

dbutils.widgets.text("catalog", "dataplatform_dev")
dbutils.widgets.text("storage_account", "stdataplatformsyrendev01")
dbutils.widgets.text("source_path", "landing/hello/")
dbutils.widgets.dropdown("source_format", "csv", ["csv", "parquet", "json"])

catalog = dbutils.widgets.get("catalog")
storage_account = dbutils.widgets.get("storage_account")
source_path = dbutils.widgets.get("source_path").strip("/")
source_format = dbutils.widgets.get("source_format")

# COMMAND ----------

# Read through the Unity Catalog external location for the raw container.
source = f"abfss://raw@{storage_account}.dfs.core.windows.net/{source_path}/"
reader = spark.read.format(source_format)
if source_format == "csv":
    reader = reader.option("header", "true")
# Select _metadata explicitly: it's a hidden column that disappears after other transformations.
raw = reader.load(source).select("*", "_metadata")
if raw.isEmpty():
    raise ValueError(f"No rows found in {source}")

# COMMAND ----------

target = f"{catalog}.raw.ingestion"
(
    raw.withColumn("_source_file", col("_metadata.file_path"))
    .drop("_metadata")
    .withColumn("_ingested_at", current_timestamp())
    .write.mode("append")
    .option("mergeSchema", "true")
    .saveAsTable(target)
)
print(f"Appended {raw.count()} row(s) from {source} to {target}")