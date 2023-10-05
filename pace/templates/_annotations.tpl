{{- define "pace.annotations.change-cause" -}}
kubernetes.io/change-cause: "Deploy of git branch '{{ .Values.gitVersion.branch }}', SHA '{{ .Values.gitVersion.sha }}'"
{{- end }}

{{/*
Common ingress annotations

Note on the parentheses in | default expansion such as the following:
  {{- if (($definition.letsEncrypt).enabled | default $.Values.ingress.main.letsEncrypt.enabled) }}
The parentheses are required in order for Helm not to throw null-pointer-errors when $definition.letsEncrypt is not defined.
Somehow the parentheses fix this and allow us to navigate deeper without throwing errors and then defaulting to the main ingress values.
See https://github.com/helm/helm/issues/8026#issuecomment-881216078
*/}}
{{- define "pace.annotations.ingress" -}}
{{- if (.local.allowedIps | default .main.allowedIps) }}
nginx.ingress.kubernetes.io/whitelist-source-range: '{{ .local.allowedIps | default .main.allowedIps }}'
{{- end }}
{{- if ((.local.letsEncrypt).enabled | default false) }}
{{- /*                                         ^
        Note: this must be false. If this was true, then it would not be possible to ever have the condition
              as false. That is because Helm will consider 'false' to be the same as 'nil' or 'unset' and will use the
              default value in that case. https://stackoverflow.com/a/74262000/428173
*/}}
cert-manager.io/cluster-issuer: "{{ (.local.letsEncrypt).clusterIssuer | default .main.letsEncrypt.clusterIssuer }}"
{{- end }}
{{- end }}