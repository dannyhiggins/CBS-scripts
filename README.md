# CBS-scripts
Cloud Block Store Automation Scripts

Collection of Pure Storage Cloud Block Store for AWS automation shell scripts used in the building a hybrid could blog post:
https://medium.com/@daniel.higgins_805/building-a-hybrid-cloud-with-pure-storage-flasharray-and-cloud-block-store-for-aws-baa62e01705b

cbs.json              - json file containing the Cloud Block Store deployment parameters
deploy_cbs_json.bash  - sheell script that uses the cbs.json parameters and the AWS CLI to deploy CBS
start_stop_ora5.bash  - shell script to automate hybrid cloud deployment and clone Oracle database from on-prem to AWS
