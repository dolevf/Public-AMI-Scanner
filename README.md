# Public-AMI-Scanner
Scans Public AWS AMIs

# Configure your AWS Credentials
Modify config.yaml and include your access_key and secret_key

# Configure your AWS region
Modify config.yaml to include your desired AWS region

# Import sql.schema into your MySQL Server
mysql -u username -p ami_scanner < schema.sql

# Install dependencies
bundle install 

# Run
ruby main.py | tee -a log.txt