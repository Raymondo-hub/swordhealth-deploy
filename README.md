# Sword Health delivery

This repository contains the GitOps configuration for the `swordhealth-prod-eks` cluster. Terraform and AWS infrastructure are managed by the infrastructure repository; Argo CD manages the AWS Load Balancer Controller and the `swordhealth/node-example` application here.

## What is managed

- `argocd/root-app.yaml` is the one-time Argo CD root Application entry point.
- `argocd/apps/` defines a restricted Argo CD project and the production child Applications.
- `charts/node-example/` is the application Helm chart.
- The production application uses the Terraform-created `node-example` service account and EKS Pod Identity association.
- The application has a namespaced Role/RoleBinding allowing only `get` and `list` on Pods in `kube-system`, as required by the challenge.
- An ingress NetworkPolicy denies pod-originated ingress and allows application traffic only from the public ALB subnets. EKS VPC CNI network-policy enforcement must remain enabled.
- The production Ingress uses the AWS Load Balancer Controller with instance targets, so the ALB routes through worker-node NodePorts. The ALB is internet-facing and HTTP-only until a domain and ACM certificate are configured.

The supplied image does not use the provisioned MySQL, S3 buckets, or SQS queue; the app chart intentionally does not invent application configuration for those challenge resources.

## Prerequisites

- The infrastructure repository has been applied to the target AWS account and region.
- The private cluster is reachable with `kubectl` through the SSM port-forward tunnel.
- Helm, `kubectl`, and Git are installed locally.
- Push this repository to the configured GitHub `main` branch before installing the root Application. The Git repository must be public or have read credentials configured in Argo CD.

The production controller Application is configured with the Terraform outputs for this cluster: cluster `swordhealth-prod-eks`, VPC `vpc-04e3c5bfe0986f739`, region `us-east-1`. The application NetworkPolicy uses the two Terraform public subnet CIDRs. For another environment, add a separate Argo CD Application and Helm values overlay with that environment's Terraform outputs rather than reusing the production values.

## Bootstrap GitOps

First connect to EKS using the private SSM tunnel as documented in the infrastructure repository. Push the delivery repo to `main`, then, from this repo root, run the idempotent bootstrap script:

```bash
./scripts/bootstrap-argocd.sh
kubectl get applications -n argocd
```

The script checks that the current kubectl context is `swordhealth-prod-eks`, installs or upgrades the pinned Argo CD Helm chart `10.11.6` with a private `ClusterIP` service, waits for the Argo CRDs, creates the app namespace, and applies the root Application. It is safe to rerun to repair or recreate the bootstrap. If your kubeconfig uses another context name for this same production cluster, set `EXPECTED_CONTEXT` to that name. This bootstrap and the GitOps configuration are production-specific; add and review a separate configuration before targeting another environment. The application namespace is created explicitly because the restricted `delivery` AppProject does not grant child Applications permission to create cluster-scoped Namespace resources. Argo CD then syncs the delivery project and child Applications from Git. The controller chart is pinned to `3.6.2`, matching the version and IAM policy provisioned by Terraform. Its service account name must remain `aws-load-balancer-controller` to match the EKS Pod Identity association. The sample app's service account must remain `node-example` in namespace `swordhealth` for the application Pod Identity association.

Check rollout and ingress status:

```bash
kubectl get applications -n argocd
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n swordhealth
kubectl get ingress -n swordhealth
```

When the AWS Load Balancer Controller reconciles the Ingress, `kubectl get ingress -n swordhealth` displays the ALB hostname in `ADDRESS`. The ALB is public and currently listens on HTTP port 80. Do not use this endpoint for sensitive traffic; configure a DNS name and ACM certificate and enable HTTPS before production use.

To access the Argo CD UI privately, keep the SSM EKS tunnel active and run:

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Then open <https://localhost:8080>. The Argo CD server remains a `ClusterIP`; do not expose it through the public application ALB.

## Helm chart checks

Lint and render the production values locally:

```bash
helm lint charts/node-example -f charts/node-example/values-prod.yaml
helm template node-example charts/node-example \
  --namespace swordhealth \
  -f charts/node-example/values-prod.yaml
```

The image is pinned to the digest for Docker Hub tag `0.0.1` because the tag is old and mutable. Review and update the image digest deliberately when a newer trusted image is provided.

## Validate the challenge demo

Run the end-to-end checks from this repository while the private EKS SSM tunnel is active. The script reads infrastructure outputs from the sibling Terraform repository, checks the private cluster, Argo CD applications, workload, ALB, AWS resources, Pod Identity and Kubernetes RBAC. It creates three temporary probe pods to verify Pod Identity/AWS access, Kubernetes API access, and cross-namespace NetworkPolicy denial; the pods are removed automatically on exit.

Prerequisites: AWS CLI v2 with the `terraform-lab` profile logged in, Terraform initialized against the production state, `kubectl` configured for the cluster through the SSM tunnel, and network access to the public ALB. Override `AWS_PROFILE`, `AWS_REGION`, or `INFRA_DIR` if using another account, region, or infrastructure repository location.

```bash
aws sso login --profile terraform-lab
./scripts/test-challenge-demo.sh
```

The script is intended for the current production demo values. A successful result exits with status 0; failed checks exit nonzero. A missing AWS Backup recovery point is reported as a warning because the first scheduled backup may not have run yet. The script does not apply Terraform, sync Argo CD, send/receive queue messages, or write test objects to S3.
