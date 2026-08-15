{{- /*
=============================================================================
Generic chart helpers. Nothing in this file names a specific chart or app --
every value is derived from .Chart / .Release, so it can be dropped into any
chart unchanged.

The values contract, all of it OPTIONAL. Every block below defaults, so a chart
that defines none of these still renders:

  nameOverride           string
  resources              {requests,limits}
  nodeSelector           map
  tolerations            list
  gpu.enabled            bool     -- false
  gpu.resourceName       string   -- "nvidia.com/gpu"  (amd.com/gpu etc. also)
  gpu.count              int      -- 1
  gpu.nodeSelector       map
  gpu.tolerations        list

configmap.yaml and the pod spec in rollout.yaml read one more optional block,
guarded the same way at the top of each file:

  config.enabled         bool     -- false
  config.env             map      -- becomes env vars via envFrom
  config.files           map      -- becomes mounted files
  config.mountPath       string   -- "/etc/config"

Do NOT reach for .Values.<block>.<key> directly in here without a `| default`
guard -- Go templates raise "nil pointer evaluating interface {}.enabled" on a
nested lookup through a block the consuming chart did not define, which is
exactly the drop-in case this file is meant to survive.
=============================================================================
*/ -}}

{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "common.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.labels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
common.configMapName / common.filesConfigMapName

Two ConfigMaps, on purpose. `config.env` is consumed with envFrom, which turns
EVERY key in the referenced ConfigMap into an environment variable -- so a file
body sharing that ConfigMap would land in the process environment as one giant
string. Keeping files in a second ConfigMap makes that impossible.
*/ -}}
{{- define "common.configMapName" -}}
{{- printf "%s-config" (include "common.fullname" .) -}}
{{- end -}}

{{- define "common.filesConfigMapName" -}}
{{- printf "%s-files" (include "common.fullname" .) -}}
{{- end -}}

{{- /*
common.nodeSelector

The generic `nodeSelector` map, plus `gpu.nodeSelector` when GPU scheduling is
on. Merged in a helper so the two can never disagree in the rendered pod spec.
Renders empty (falsey to `with`) when both are empty, so no `nodeSelector: {}`
is emitted.
*/ -}}
{{- define "common.nodeSelector" -}}
{{- $gpu := .Values.gpu | default dict -}}
{{- $sel := deepCopy (.Values.nodeSelector | default dict) -}}
{{- if $gpu.enabled -}}
{{- $sel = merge $sel ($gpu.nodeSelector | default dict) -}}
{{- end -}}
{{- if $sel }}{{ toYaml $sel }}{{ end -}}
{{- end -}}

{{- /*
common.tolerations

Same idea, but lists concat rather than merge. The GPU toleration is what lets
the pod land on a node tainted `nvidia.com/gpu=present:NoSchedule` -- the taint
is how you keep CPU-only workloads off expensive hardware.
*/ -}}
{{- define "common.tolerations" -}}
{{- $gpu := .Values.gpu | default dict -}}
{{- $tol := .Values.tolerations | default list -}}
{{- if $gpu.enabled -}}
{{- $tol = concat $tol ($gpu.tolerations | default list) -}}
{{- end -}}
{{- if $tol }}{{ toYaml $tol }}{{ end -}}
{{- end -}}

{{- /*
common.resources

`.Values.resources` with the GPU count spliced into limits when gpu.enabled.

`nvidia.com/gpu` is an EXTENDED resource, and those have two rules the ordinary
cpu/memory ones do not: it must appear under limits, and if it also appears
under requests the two must be equal. Setting it in limits only -- as here --
makes Kubernetes copy the value into requests itself, so the two can never drift
apart. Never put a GPU in requests alone; the pod schedules and then gets no
device.
*/ -}}
{{- define "common.resources" -}}
{{- $gpu := .Values.gpu | default dict -}}
{{- $res := deepCopy (.Values.resources | default dict) -}}
{{- if $gpu.enabled -}}
{{- $name := $gpu.resourceName | default "nvidia.com/gpu" -}}
{{- $count := $gpu.count | default 1 -}}
{{- $limits := deepCopy ($res.limits | default dict) -}}
{{- $setLimit := set $limits $name $count -}}
{{- $setRes := set $res "limits" $setLimit -}}
{{- end -}}
{{- toYaml $res -}}
{{- end -}}
