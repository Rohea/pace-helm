{{- define "deployment.sentry-relay" }}
{{- if .Values.sentry.enabled }}
- name: sentry-relay
  image: getsentry/relay
  args:
    - run
  ports:
    - containerPort: 3000
  imagePullPolicy: Always
  env:
    - name: RELAY_UPSTREAM_URL
      value: https://sentry.rohea.com
    - name: RELAY_MODE
      value: proxy
    - name: RELAY_HOST
      value: 0.0.0.0
  resources:
    requests:
      memory: 16Mi
      cpu: 5m
    limits:
      memory: 64Mi
      cpu: 50m
{{- end }}
{{- end }}