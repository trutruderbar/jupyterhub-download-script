{{- define "jhub.nicpolicy" -}}
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: {{ .policy_name }}
spec:
  numAounetworkOperatorPolicyCr: {}
{{- end -}}
