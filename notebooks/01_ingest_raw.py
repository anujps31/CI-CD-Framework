from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()
# Use the supplied catalog so the raw table is created in the intended Dev namespace.
# The pipeline/DAB should provide catalog; this default is for local notebook testing only.
catalog = dbutils.widgets.get("catalog") if "catalog" in [w.name for w in dbutils.widgets.getAll()] else "dataplatform_dev"

# Replace this source with the project-specific landing zone before production use.
source_path = f"abfss://raw@storage{catalog.replace('_', '')}.dfs.core.windows.net/"
raw = spark.read.format("parquet").load(source_path)
raw.write.mode("append").format("delta").saveAsTable(f"{catalog}.raw.ingestion")
