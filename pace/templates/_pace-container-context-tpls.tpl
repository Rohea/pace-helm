{{/******************************************************************************************************************/}}

{{- define "pace.envFrom" -}}
{{- if eq .Values.deployContext "microk8s" -}}
- configMapRef:
    name: pace
{{- end }}
{{- if eq .Values.deployContext "azure" -}}
{{- end }}
{{- end -}}

{{- define "pace.volumeMounts" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- mountPath: /pace/.env.local
  name: pace-config-secret-volume
  subPath: pace-env
- name: tls-secret-store
  mountPath: "/mnt/tls-secret"
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "pace.volumes" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- name: pace-config-secret-volume
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: pace-config-secret
- name: tls-secret-store
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: "tls-cert-provider"
{{- end -}}
{{- end -}}

{{/******************************************************************************************************************/}}

{{- define "pace.migrations.envFrom" -}}
{{- if eq .Values.deployContext "microk8s" -}}
- configMapRef:
    name: pace
- configMapRef:
    name: migrations
- secretRef:
    name: migrations-bootstrap-credentials
    optional: true
{{- end }}
{{- if eq .Values.deployContext "azure" -}}
{{- end }}
{{- end -}}

{{- define "pace.migrations.volumeMounts" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- mountPath: /pace/.env.local
  name: pace-config-secret-volume
  subPath: pace-env
{{- end -}}
{{- end -}}

{{- define "pace.migrations.volumes" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- name: pace-config-secret-volume
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: pace-config-secret
{{- end -}}
{{- end -}}

{{/******************************************************************************************************************/}}

{{- define "pace.statsd.envFrom" -}}
- configMapRef:
    name: statsd-env
{{- if eq .Values.deployContext "microk8s" -}}
{{- end }}
{{- if eq .Values.deployContext "azure" }}
- secretRef:
    name: statsd-mongo-connection-string
{{- end }}
{{- end -}}
{{- define "pace.statsd.volumeMounts" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- mountPath: /mnt/env
  name: statsd-config-secret-volume
  subPath: statsd-env
{{- end -}}
{{- end -}}

{{- define "pace.statsd.volumes" -}}
{{- if eq .Values.deployContext "microk8s" -}}{{- end -}}
{{- if eq .Values.deployContext "azure" -}}
- name: statsd-config-secret-volume
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: statsd-config-secret
{{- end -}}
{{- end -}}