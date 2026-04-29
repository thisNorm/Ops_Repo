{{/*
공통 라벨 정의 — 모든 리소스에서 재사용
*/}}
{{- define "team-board.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
