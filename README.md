# Argo ML Workloads Lab

This repo is a local GitOps lab for deploying the same small ML-adjacent
inference service several ways with Argo CD.

The workload is intentionally simple: a Python HTTP API that runs from a
ConfigMap mounted into `python:3.12-slim`. That means you can focus on Argo CD,
Kubernetes objects, Helm rendering, and Argo Rollouts without first building and
pushing a custom image.

## Layout

```text
apps/
  plain-k8s.yaml          Argo CD Application for raw Kubernetes YAML
  helm.yaml               Argo CD Application for the Helm chart
  rollout.yaml            Argo CD Application for Argo Rollouts
  kustomize/dev.yaml      Dev cluster app using Kustomize overlays
  kustomize/prod.yaml     Prod cluster app using Kustomize overlays
  helm/dev.yaml           Dev cluster app using Helm values
  helm/prod.yaml          Prod cluster app using Helm values
workloads/
  k8s/                    Plain Kubernetes Deployment + Service + ConfigMap
  kustomize/              Kustomize base plus dev/prod overlays
  helm/ml-inference/      Helm chart for the same service
  rollouts/               Argo Rollouts blue-green version
scripts/
  curl-predict.sh         Tiny smoke test for the API
```

## What The Service Does

The API exposes:

```text
GET  /healthz
GET  /model
GET  /metrics
POST /predict
```

Example request:

```bash
curl -s http://localhost:8081/predict \
  -H 'content-type: application/json' \
  -d '{"features":{"age":42,"sessions":8,"support_tickets":1},"text":"trial user asked about export limits"}'
```

Example response:

```json
{
  "model": "toy-churn-risk",
  "version": "0.1.0",
  "score": 0.3464,
  "label": "low_risk"
}
```

## Push This Repo First

This repo is public, so Argo CD can read it without GitHub credentials.

```bash
git branch -M main
git remote add origin https://github.com/sammaher1/argo-ml-workloads.git
git push -u origin main
```

## Two Local Clusters

For multi-cluster practice, use the cluster already running Argo CD as `dev`
and create a second Kind cluster as `prod`.

```bash
kind create cluster --name argo-prod
```

Register the prod cluster with Argo CD. The `--name prod` part is important
because the prod Argo CD Applications in this repo use `destination.name: prod`.

```bash
argocd cluster add kind-argo-prod --name prod
```

After that, the shape is:

```text
dev Kind cluster:
  runs Argo CD
  receives dev workloads through https://kubernetes.default.svc

prod Kind cluster:
  receives prod workloads through the registered Argo CD cluster named prod
```

## Dev/Prod With Kustomize

Kustomize starts with normal Kubernetes YAML in a base and applies structured
patches for each environment.

```text
workloads/kustomize/base/
  deployment.yaml
  service.yaml
  server.py
  kustomization.yaml

workloads/kustomize/overlays/dev/
  kustomization.yaml
  deployment-patch.yaml

workloads/kustomize/overlays/prod/
  kustomization.yaml
  deployment-patch.yaml
```

Render locally without applying:

```bash
kubectl kustomize workloads/kustomize/overlays/dev
kubectl kustomize workloads/kustomize/overlays/prod
```

The dev overlay changes the base to:

```text
replicas: 1
MODEL_VERSION: 0.2.0-dev
ENVIRONMENT: dev
smaller CPU/memory limits
```

The prod overlay changes the same base to:

```text
replicas: 3
MODEL_VERSION: 1.0.0
ENVIRONMENT: prod
larger CPU/memory limits
```

Apply the Argo CD Applications:

```bash
kubectl apply -n argocd -f apps/kustomize/dev.yaml
kubectl apply -n argocd -f apps/kustomize/prod.yaml
```

## Dev/Prod With Helm

Helm starts with templates and fills them using values files.

```text
workloads/helm/ml-inference/
  Chart.yaml
  values.yaml
  values-dev.yaml
  values-prod.yaml
  templates/
```

Render locally without applying:

```bash
helm template ml-inference workloads/helm/ml-inference -f workloads/helm/ml-inference/values-dev.yaml
helm template ml-inference workloads/helm/ml-inference -f workloads/helm/ml-inference/values-prod.yaml
```

The dev and prod Helm apps point at the same chart path, but use different
values files:

```bash
kubectl apply -n argocd -f apps/helm/dev.yaml
kubectl apply -n argocd -f apps/helm/prod.yaml
```

## Deploy The Plain Kubernetes Version

This is the most direct path. Argo CD reads YAML files and applies them.

```bash
kubectl apply -n argocd -f apps/plain-k8s.yaml
```

What Argo CD will create in namespace `ml-lab-k8s`:

```text
ConfigMap   ml-inference-script
Deployment  ml-inference
Service     ml-inference
```

Watch it:

```bash
argocd app get ml-inference-k8s
kubectl get deploy,rs,pods,svc -n ml-lab-k8s
```

Port-forward it:

```bash
kubectl port-forward -n ml-lab-k8s svc/ml-inference 8081:80
./scripts/curl-predict.sh 8081
```

## Deploy The Helm Version

This tests a different packaging mechanism. Argo CD renders the chart, then
applies the rendered Kubernetes objects.

```bash
kubectl apply -n argocd -f apps/helm.yaml
```

Watch it:

```bash
argocd app get ml-inference-helm
kubectl get deploy,rs,pods,svc -n ml-lab-helm
```

The key learning point: Kubernetes still receives a Deployment, Service, and
ConfigMap. Helm changes how those objects are generated, not what Kubernetes
fundamentally runs.

## Deploy The Argo Rollouts Version

Argo Rollouts is a separate controller from Argo CD. Argo CD can apply a
`Rollout` object, but the Rollouts controller must be installed first or the
cluster will not recognize the custom resource.

Install Argo Rollouts:

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Then apply the Argo CD app:

```bash
kubectl apply -n argocd -f apps/rollout.yaml
```

Watch it:

```bash
argocd app get ml-inference-rollout
kubectl get rollouts,pods,svc -n ml-lab-rollout
```

This version uses blue-green deployment:

```text
Rollout -> ReplicaSets -> Pods
active Service -> current stable ReplicaSet
preview Service -> next candidate ReplicaSet
```

When you change the model version in Git, Argo CD applies the new Rollout spec.
Argo Rollouts then decides how traffic should move between old and new pods.

## Exercises

1. Scale drift:

   ```bash
   kubectl scale deployment ml-inference -n ml-lab-k8s --replicas=3
   argocd app get ml-inference-k8s
   ```

   Argo CD should report `OutOfSync` because Git says `replicas: 2`.

2. Git-driven model version change:

   Change `MODEL_VERSION` in `workloads/k8s/deployment.yaml`, commit it, push it,
   then sync the Argo CD app.

3. Compare deployment mechanisms:

   Inspect what each path creates:

   ```bash
   kubectl get all,cm -n ml-lab-k8s
   kubectl get all,cm -n ml-lab-helm
   kubectl get all,cm,rollouts -n ml-lab-rollout
   ```

## Cleanup

Delete the Argo CD Applications:

```bash
kubectl delete -n argocd -f apps/plain-k8s.yaml
kubectl delete -n argocd -f apps/helm.yaml
kubectl delete -n argocd -f apps/rollout.yaml
```

Delete namespaces if you want to remove all workload resources:

```bash
kubectl delete namespace ml-lab-k8s ml-lab-helm ml-lab-rollout
```
