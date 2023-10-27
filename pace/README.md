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

## Components

### Mercure

See the [values.yaml](values.yaml) file and the `mercure` root key for all configuration options.

The Mercure component runs as a standalone pod in the same namespace as the rest of the Pace application. It is
available in-cluster via a service and exposed through an Ingress at 

```
https://base.pace.url/.well-known/mercure
```

For development, it may be useful to enable the `mercure.debug` mode and get an admin web UI for testing events:

```
https://base.pace.url/.well-known/mercure/ui/
```

Project's [GitHub](https://github.com/dunglas/mercure).

#### JWT verification and secrets

Mercure requires setup for JWT secrets - one for the publisher, one for subscriber.

In automated environments (most notably stagings) this is done automatically
in [setup-configmaps-and-secrets.sh](../../../../tools/k8s/setup-configmaps-and-secrets.sh). In "manual" environments, a
Kubernetes secret named `mercure` is required to be created manually. See the script for how to do that.

https://mercure.rocks/docs/hub/config

## How-tos

### Trust a custom root CA
To trust a custom root CA, mount the CA certificate into the pod from a secret.

```bash
$ kubectl create secret generic custom-root-ca-secret --from-file=root-ca-crt-in-secret.crt=root-ca-file.crt
```

```yaml
web:
  volumes:
    - name: custom-root-ca-vol 
      secret:
        secretName: custom-root-ca-secret

  volumeMounts:
    - name: custom-root-ca-vol
      mountPath: /usr/local/share/ca-certificates/root-ca-name.crt
      subPath: root-ca-crt-in-secret.crt
```