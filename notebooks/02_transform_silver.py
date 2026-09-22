from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()
# Transform the governed raw table and publish the cleaned result to the silver schema.
# Supply the catalog widget from the Databricks job or bundle configuration.
catalog = dbutils.widgets.get("catalog")
raw = spark.table(f"{catalog}.raw.ingestion")
silver = raw.dropDuplicates()
silver.write.mode("overwrite").format("delta").saveAsTable(f"{catalog}.silver.ingestion")
