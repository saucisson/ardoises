# Information for Developers

## Error reporting

## Localtunnel

```shell
  $ lt --port 8080 --subdomain ardoises
  $ ssh -R 80:127.0.0.1:8080 root@ardoises.ovh -N
  $ ssh -R 8443:127.0.0.1:8443 root@ardoises.ovh -N
```

```
mkdir -p /etc/nginx/ssl
openssl rand 48 -out /etc/nginx/ssl/ticket.key
openssl dhparam -dsaparam -out /etc/nginx/ssl/dhparam4.pem

certbot certonly \
  --rsa-key-size 4096 \
  --webroot \
  --webroot-path ./data \
  -d ardoises.ovh

certbot renew \
  --webroot \
  --webroot-path ./data

certbot \
  --non-interactive \
  --agree-tos \
  --email=admin@ardoises.ovh \
  register
certbot \
  certonly \
  --standalone \
  -d "ardoises.ovh"


  -w "/" \
```
