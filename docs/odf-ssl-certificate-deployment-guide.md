# ODF SSL Certificate Management Deployment Guide

This guide provides step-by-step instructions for deploying the enhanced ODF SSL certificate management policies that follow Red Hat's official documentation guidelines.

## Overview

The enhanced certificate management system provides automated SSL certificate extraction, distribution, and configuration specifically designed for OpenShift Data Foundation (ODF) disaster recovery scenarios.

## New Policy Files

### 1. **Main Certificate Management Policy**

- **File:** `charts/hub/opp/templates/policy-odf-ssl-certificate-management.yaml`

- **Purpose:** Extracts certificates from all clusters and creates distribution policies

- **Features:** Automated cluster discovery, certificate extraction, CA bundle creation

### 2. **Managed Cluster SSL Policy**

- **File:** `charts/hub/opp/templates/policy-odf-managed-cluster-ssl.yaml`

- **Purpose:** Ensures managed clusters have proper SSL certificate configuration

- **Features:** ConfigMap creation, proxy configuration, ODF verification

### 3. **Placement Rule**

- **File:** `charts/hub/opp/templates/placement-odf-ssl-certificates.yaml`

- **Purpose:** Targets regional DR clusters for certificate distribution

- **Features:** Cluster selection, availability checks, regional DR support

### 4. **Placement Binding**

- **File:** `charts/hub/opp/templates/placement-binding-odf-ssl.yaml`

- **Purpose:** Connects placement rule with managed cluster policy

- **Features:** Policy distribution, cluster targeting

## Deployment Instructions

### Step 1: Deploy the Enhanced Policies

The new policies will be automatically deployed when you apply the hub policy set:

```bash
# Navigate to the project directory
cd /home/martjack/gitwork/ramendr-starter-kit

# Apply the hub policies (includes the new ODF SSL certificate management)
oc apply -f charts/hub/opp/templates/

```text

### Step 2: Verify Policy Deployment

Check that all policies are created:
```bash
# Check main certificate management policy
oc get policy policy-odf-ssl-certificate-management -n open-cluster-management

# Check managed cluster SSL policy
oc get policy policy-odf-managed-cluster-ssl -n open-cluster-management

# Check placement rule
oc get placementrule placement-odf-ssl-certificates -n open-cluster-management

# Check placement binding
oc get placementbinding binding-odf-ssl-certificates -n open-cluster-management

```text

### Step 3: Monitor Certificate Extraction

The main policy creates a job that extracts certificates from all clusters:
```bash
# Check job status
oc get job odf-ssl-certificate-extractor -n openshift-config

# Monitor job logs
oc logs -f job/odf-ssl-certificate-extractor -n openshift-config

```text

### Step 4: Verify Certificate Distribution

Check that certificates are distributed to all clusters:
```bash
# Verify hub cluster configuration
oc get configmap cluster-proxy-ca-bundle -n openshift-config
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'

# Check managed cluster policies (run on each managed cluster)
oc get configmap cluster-proxy-ca-bundle -n openshift-config
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'

```text
## Key Improvements
### 1. **ODF-Specific Configuration**

- Follows Red Hat ODF disaster recovery guidelines

- Targets clusters with `purpose: regionalDR` labels

- Supports MirrorPeer and DRCluster SSL requirements
### 2. **Enhanced Certificate Extraction**

- Multiple extraction methods for reliability

- Automatic cluster discovery via ACM

- Handles kubeconfig management for managed clusters
### 3. **Comprehensive Distribution**

- Creates placement rules for targeted distribution

- Ensures proper policy application to managed clusters

- Supports 2-cluster regional DR configurations
### 4. **Automated Management**

- No manual certificate configuration required

- Self-healing certificate distribution

- Automatic retry and recovery mechanisms

## Verification Commands
### Check Policy Status

```bash
# Main certificate management policy
oc get policy policy-odf-ssl-certificate-management -n open-cluster-management -o yaml

# Managed cluster SSL policy
oc get policy policy-odf-managed-cluster-ssl -n open-cluster-management -o yaml

# Placement rule
oc get placementrule placement-odf-ssl-certificates -n open-cluster-management -o yaml

# Placement binding
oc get placementbinding binding-odf-ssl-certificates -n open-cluster-management -o yaml

```text

### Monitor Certificate Extraction

```bash
# Job status
oc get job odf-ssl-certificate-extractor -n openshift-config

# Job logs
oc logs job/odf-ssl-certificate-extractor -n openshift-config

# Service account and RBAC
oc get sa odf-ssl-extractor-sa -n openshift-config
oc get clusterrole odf-ssl-extractor-role
oc get clusterrolebinding odf-ssl-extractor-rolebinding

```text

### Verify SSL Configuration

```bash
# Hub cluster
oc get configmap cluster-proxy-ca-bundle -n openshift-config
oc get proxy cluster -o yaml

# Managed clusters (run on each cluster)
oc get configmap cluster-proxy-ca-bundle -n openshift-config
oc get proxy cluster -o yaml
oc get configmap odf-ssl-verification -n openshift-storage

```text
## Troubleshooting
### Common Issues

1. **Job Fails to Start**
   ```bash
   # Check service account permissions
   oc get sa odf-ssl-extractor-sa -n openshift-config
   oc describe clusterrole odf-ssl-extractor-role
   oc describe clusterrolebinding odf-ssl-extractor-rolebinding
   ```

1. **Certificate Extraction Fails**

   ```bash
   # Check job logs for specific errors
   oc logs job/odf-ssl-certificate-extractor -n openshift-config

   # Verify cluster connectivity
   oc get managedclusters
   oc get managedclusterinfo -n <cluster-name>
   ```

2. **Policy Distribution Issues**

   ```bash
   # Check placement rule status
   oc get placementrule placement-odf-ssl-certificates -n open-cluster-management -o yaml

   # Check placement binding
   oc get placementbinding binding-odf-ssl-certificates -n open-cluster-management -o yaml

   # Check policy compliance
   oc get policy policy-odf-managed-cluster-ssl -n open-cluster-management -o yaml
   ```

### Manual Trigger

To manually trigger certificate extraction:

```bash
# Delete the existing job to trigger recreation
oc delete job odf-ssl-certificate-extractor -n openshift-config

# The policy will automatically recreate the job

```text
## Expected Results

After successful deployment, you should see:

1. **Hub Cluster:**

   - `cluster-proxy-ca-bundle` ConfigMap in `openshift-config` namespace

   - Proxy configuration updated to use the CA bundle

   - Certificate extraction job completed successfully

2. **Managed Clusters:**

   - `cluster-proxy-ca-bundle` ConfigMap in `openshift-config` namespace

   - Proxy configuration updated to use the CA bundle

   - `odf-ssl-verification` ConfigMap in `openshift-storage` namespace

3. **ACM Policies:**

   - All policies created and compliant

   - Placement rules targeting correct clusters

   - Certificate distribution working across all clusters

## Benefits
- **ODF Compliance:** Follows Red Hat ODF disaster recovery guidelines

- **Automated Management:** No manual certificate configuration required

- **Security:** Ensures SSL trust across all clusters

- **Reliability:** Multiple extraction methods and self-healing

- **Monitoring:** Comprehensive logging and status reporting

This enhanced certificate management system provides a robust, automated solution for SSL certificate management in ODF disaster recovery scenarios, following Red Hat's official documentation and best practices.
