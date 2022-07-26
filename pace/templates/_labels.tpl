{{/*
Pace component base labels

The template expects a dict:
{
  "component": "component-name",
  "global": $.Values
}
Construct as:
  {{ $componentDict := dict "component" $componentName "global" $.Values }}
*/}}
{{- define "pace.labels.component" -}}
rohea.com/installation: {{ .global.installationSlug }}
rohea.com/app: pace
rohea.com/component: {{ .component }}
{{- end }}