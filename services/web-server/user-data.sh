#!/bin/bash
cat > index.html <<EOF
<html>
  <head>
    <title>Terraform with AWS</title>
  </head>
  <body>
    <h1>Learn Terraform with AWS</h1>
    <p>DB Address: ${db_address}</p>
    <p>DB Port: ${db_port}</p>
  </body>
</html>
EOF

nohup busybox httpd -f -p ${server_port} &