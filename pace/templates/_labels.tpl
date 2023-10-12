{{/* -------------------------------------------------------------------------------------------------------------------
Pace component base labels

The template expects a dict:
{
  "component": "component-name",
  "global": $.Values
}
Construct as:
  {{ $componentDict := dict "component" $componentName "global" $.Values }}

Note that these labels are used as the selector matchLabels. Changing these will result in kubectl-apply errors, unless
all existing Deployment objects are deleted first. If you want to change common Rohea/Pace labels, check out the
template 'pace.labels.common' below.
*/}}
{{- define "pace.labels.component" -}}
rohea.com/installation: {{ .global.installationSlug }}
rohea.com/app: pace
rohea.com/component: {{ .component }}
rohea.com/deploy-environment: {{ .global.gitlab.gitlabEnvironment }}
rohea.com/collect_logs: 'true'
rohea.com/collect_metrics: 'true'
{{- end }}

{{/*
Selector labels used in spec.selector.matchLabels.
Note that these labels are ONLY used as matchLabels, they are not defined onto any object. It is up to you to ensure
that the selector labels match labels from e.g. pace.labels.component
*/}}
{{- define "pace.labels.selectorLabels" -}}
rohea.com/installation: {{ .global.installationSlug }}
rohea.com/app: pace
rohea.com/component: {{ .component }}
{{- end }}

{{/* -------------------------------------------------------------------------------------------------------------------
Label for resources that should be considered for removing in subsequent deploys.

Best shown with an example:
  - Deploy #1 creates a stack and includes some network policy resources
  - Deploy #2 does not have the network policy resources in the to-deploy-YAML manifest anymore. But kubectl apply does not auto-remove those "orphaned" resources.
      As a solution, the deploy script lists all resources with meta.rohea.com/resource-clearable="true"  AND  meta.rohea.com/deploy-tag NOT equal to the currently-deployed tag.
      Resources listed this way are the resources that
        a) were tagged as clearable (i.e. they are not some setup-once-and-keep-always like in Azure), and
        b) were deployed previously and not now (because the deployTag value is different and unique for each deploy)
      Such resources are then removed.
*/}}
{{- define "pace.labels.deployTag" -}}
meta.rohea.com/deploy-tag: "{{ .Values.deployTag }}"
meta.rohea.com/resource-clearable: "true"
{{- end }}
