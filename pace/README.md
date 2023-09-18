# Pace Helm chart

## Deployment requirements

### JWT secrets

The chart expects a Kubernetes secret in the namespace where it is deployed. The secret must contain two keys - the
private and the public key to use for the JWT authentication mechanism.

This is done automatically when using the `upsert-configmaps.sh` script in a deployment. Otherwise, you will need to
create the secret yourself.

The secret **must** be named `jwt`. It **must** contain the following two keys: `private.pem` and `public.pem`. Use the
PHP `bin/console` command to create the keys.

```bash
$ export JWT_PUBLIC_KEY=public.pem 
$ export JWT_SECRET_KEY=private.pem
$ export JWT_PASSPHRASE=
$ bin/console lexik:jwt:generate-keypair

$ kubectl create secret generic jwt --from-file private.pem --from-file public.pem
```

The secret is mounted into the running web container as two files under `/pace/config/jwt/kubernetes/`. Unless
overridden, the container is configured with environment variables to load the JWT secrets from that location, nothing 
else needs to be done.
