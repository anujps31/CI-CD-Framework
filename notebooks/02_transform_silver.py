# Databricks notebook source
# Clean the raw ingestion table and publish it to <catalog>.silver.ingestion.
dbutils.widgets.text("catalog", "dataplatform_dev")
catalog = dbutils.widgets.get("catalog")

# COMMAND ----------

raw = spark.table(f"{catalog}.raw.ingestion")
# Drop ingestion metadata before de-duplicating, so re-ingesting the same file doesn't duplicate rows.
business_columns = [c for c in raw.columns if not c.startswith("_")]
silver = raw.select(*business_columns).dropDuplicates()

target = f"{catalog}.silver.ingestion"
silver.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(target)
print(f"Wrote {silver.count()} row(s) to {target}")