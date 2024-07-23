{{/******************************************************************************************************************/}}

{{- define "pace.envFrom" }}
{{/*
- The order of preference when importing env variables is "last imported wins". Lower priority thus need to be imported
  first.
*/}}
{{- if eq .Values.deployContext "microk8s" }}
- configMapRef:
    name: pace
{{- end }}

- secretRef:
    name: mercure
    optional: true
- configMapRef:
    name: mercure-helm
    optional: true
- configMapRef:
    name: php-helm
- configMapRef:
    name: pace-helm

{{- if eq .Values.deployContext "azure" }}
{{- end }}
{{- end }}

{{- define "pace.volumeMounts" }}
- name: jwt-secret-volume
  mountPath: "/pace/config/jwt/kubernetes/"
  readOnly: true
{{- if eq .Values.deployContext "microk8s" }}{{- end }}
{{- if eq .Values.deployContext "azure" }}

{{/* See FEN-1579. This /mnt/envvars/ mounting should become the default once it's properly tested. */}}
{{- if .Values.featureFlags.newSecretsMount }}
- mountPath: /mnt/envvars/
  name: pace-config-secret-volume
{{- else }}
- mountPath: /pace/.env.local
  name: pace-config-secret-volume
  subPath: pace-env
{{- end }}

{{- if .Values.ingress.main.tls.mountTlsSecretStore }}
- name: tls-secret-store
  mountPath: "/mnt/tls-secret"
  readOnly: true
{{- end }}
{{- end }}
{{- end }}

{{- define "pace.volumes" }}
- name: jwt-secret-volume
  secret:
    secretName: jwt
{{- if eq .Values.deployContext "microk8s" }}{{- end }}
{{- if eq .Values.deployContext "azure" }}
- name: pace-config-secret-volume
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: pace-config-secret
{{- if .Values.ingress.main.tls.enabled }}
- name: tls-secret-store
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: "tls-cert-provider"
{{- end }}
{{- end }}
{{- end }}

{{/******************************************************************************************************************/}}

{{- define "pace.migrations.envFrom" }}
{{- if eq .Values.deployContext "microk8s" }}
- secretRef:
    name: migrations-bootstrap-credentials
    optional: true
{{- end }}
{{- if eq .Values.deployContext "azure" }}
{{- end }}
{{- end }}

{{/******************************************************************************************************************/}}

{{- define "pace.statsd.envFrom" }}
- configMapRef:
    name: statsd-env
{{- if eq .Values.deployContext "microk8s" }}
{{- end }}
{{- if eq .Values.deployContext "azure" }}
- secretRef:
    name: statsd-mongo-connection-string
{{- end }}
{{- end }}
{{- define "pace.statsd.volumeMounts" }}
{{- if eq .Values.deployContext "microk8s" }}{{- end }}
{{- if eq .Values.deployContext "azure" }}
- mountPath: /mnt/env
  name: statsd-config-secret-volume
  subPath: statsd-env
{{- end }}
{{- end }}

{{- define "pace.statsd.volumes" }}
{{- if eq .Values.deployContext "microk8s" }}{{- end }}
{{- if eq .Values.deployContext "azure" }}
- name: statsd-config-secret-volume
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: statsd-config-secret
{{- end }}
{{- end }}

{{/******************************************************************************************************************/}}
{{- /*
SP-83 Running containers as root user should be avoided
*/}}
{{- define "pace-php.security.runAsRohea" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
{{- end }}
