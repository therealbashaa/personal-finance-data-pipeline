import os
import boto3

# 1. Configure your paths and bucket
LOCAL_FOLDER = 'C:\\Qucik_Shifter\\DE_Projects\\finance_data_platform\\source_data\\ingest_data'  # Update with your local folder path
BUCKET_NAME = 's3-fdp-bucket'          # Update with your bucket name
S3_FOLDER = 'raw'               # Update with your S3 folder prefix

# 2. Initialize the S3 client
s3 = boto3.client('s3')

# 3. Iterate and upload files
print(f"Starting bulk upload from '{LOCAL_FOLDER}' to 's3://{BUCKET_NAME}/{S3_FOLDER}'...\n")

for filename in os.listdir(LOCAL_FOLDER):
    local_path = os.path.join(LOCAL_FOLDER, filename)
    
    # Ensure we are only uploading files, not subdirectories
    if os.path.isfile(local_path):
        # Create the full destination path in S3
        s3_key = f"{S3_FOLDER}/{filename}"
        
        # Upload the file
        s3.upload_file(local_path, BUCKET_NAME, s3_key)
        print(f"Successfully uploaded: {filename}")

print("\nAll files have been successfully uploaded!")
