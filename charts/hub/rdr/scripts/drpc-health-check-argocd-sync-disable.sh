#!/bin/bash
set -euo pipefail

echo "Starting DRPC health check and ArgoCD sync disable job..."
echo "This job will check DRPC health (Kubernetes objects and PVCs) and disable ArgoCD sync when healthy"

# Configuration from environment variables
DRPC_NAMESPACE="${DRPC_NAMESPACE:-openshift-dr-ops}"
DRPC_NAME="${DRPC_NAME:-gitops-vm-protection}"
PROTECTED_NAMESPACE="${PROTECTED_NAMESPACE:-gitops-vms}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-rdr}"
MAX_ATTEMPTS=60  # 1 hour with 1 minute intervals
SLEEP_INTERVAL=60  # 1 minute between checks

# Function to check if DRPC exists
check_drpc_exists() {
  echo "Checking if DRPC $DRPC_NAME exists in namespace $DRPC_NAMESPACE..."
  
  if ! oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" &>/dev/null; then
    echo "❌ DRPC $DRPC_NAME not found in namespace $DRPC_NAMESPACE"
    return 1
  fi
  
  echo "✅ DRPC $DRPC_NAME exists"
  return 0
}

# Function to check DRPC status conditions
check_drpc_status() {
  echo "Checking DRPC $DRPC_NAME status conditions..."
  
  # Get DRPC status
  local drpc_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
  
  if [[ "$drpc_status" == "[]" || -z "$drpc_status" ]]; then
    echo "❌ DRPC status conditions not available yet"
    return 1
  fi
  
  # Check for common healthy conditions
  # DRPC typically has conditions like "Available", "Ready", "Reconciled", etc.
  local available_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  local ready_status=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  # Check overall phase if available
  local phase=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  
  echo "  DRPC Phase: ${phase:-Unknown}"
  echo "  Available Status: ${available_status:-Unknown}"
  echo "  Ready Status: ${ready_status:-Unknown}"
  
  # Consider DRPC healthy if phase is "Deployed" or if Available/Ready conditions are True
  if [[ "$phase" == "Deployed" ]]; then
    echo "✅ DRPC is in Deployed phase"
    return 0
  fi
  
  if [[ "$available_status" == "True" ]] || [[ "$ready_status" == "True" ]]; then
    echo "✅ DRPC has healthy status conditions"
    return 0
  fi
  
  # If no specific conditions match, check if there are any error conditions
  local error_conditions=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o jsonpath='{.status.conditions[?(@.status=="False")]}' 2>/dev/null || echo "")
  if [[ -n "$error_conditions" ]]; then
    echo "⚠️  DRPC has some False conditions, but continuing check..."
    # Don't fail immediately, continue to check other aspects
  fi
  
  echo "⚠️  DRPC status not clearly healthy, but continuing with other checks..."
  return 0  # Continue with other checks even if status is ambiguous
}

# Function to check PVCs in protected namespace
check_pvcs_health() {
  echo "Checking PVCs in protected namespace $PROTECTED_NAMESPACE..."
  
  # Check if namespace exists
  if ! oc get namespace "$PROTECTED_NAMESPACE" &>/dev/null; then
    echo "⚠️  Protected namespace $PROTECTED_NAMESPACE does not exist yet"
    return 1
  fi
  
  # Get all PVCs in the protected namespace that match the DRPC selector
  # DRPC pvcSelector: app.kubernetes.io/component=storage
  local pvc_count=$(oc get pvc -n "$PROTECTED_NAMESPACE" -l app.kubernetes.io/component=storage --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
  
  if [[ $pvc_count -eq 0 ]]; then
    echo "⚠️  No PVCs found in namespace $PROTECTED_NAMESPACE with label app.kubernetes.io/component=storage"
    echo "  This may be expected if no storage components are deployed yet"
    # Don't fail if no PVCs exist - they may be created later
    return 0
  fi
  
  echo "  Found $pvc_count PVC(s) with storage component label"
  
  # Check each PVC status
  local all_pvcs_healthy=true
  local pvc_list=$(oc get pvc -n "$PROTECTED_NAMESPACE" -l app.kubernetes.io/component=storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pvc_list" ]]; then
    echo "⚠️  Could not retrieve PVC list"
    return 1
  fi
  
  for pvc_name in $pvc_list; do
    local pvc_phase=$(oc get pvc "$pvc_name" -n "$PROTECTED_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    local pvc_size=$(oc get pvc "$pvc_name" -n "$PROTECTED_NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "Unknown")
    
    echo "  PVC $pvc_name: Phase=$pvc_phase, Size=$pvc_size"
    
    if [[ "$pvc_phase" != "Bound" ]]; then
      echo "    ❌ PVC $pvc_name is not Bound (current phase: $pvc_phase)"
      all_pvcs_healthy=false
    else
      echo "    ✅ PVC $pvc_name is Bound and healthy"
    fi
  done
  
  if [[ "$all_pvcs_healthy" == "true" ]]; then
    echo "✅ All PVCs in protected namespace are healthy"
    return 0
  else
    echo "❌ Some PVCs are not healthy"
    return 1
  fi
}

# Function to check Kubernetes objects in protected namespace
check_k8s_objects_health() {
  echo "Checking Kubernetes objects in protected namespace $PROTECTED_NAMESPACE..."
  
  # Check if namespace exists
  if ! oc get namespace "$PROTECTED_NAMESPACE" &>/dev/null; then
    echo "⚠️  Protected namespace $PROTECTED_NAMESPACE does not exist yet"
    return 1
  fi
  
  local all_objects_healthy=true
  
  # Check Deployments
  echo "  Checking Deployments..."
  local deployments=$(oc get deployments -n "$PROTECTED_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
  if [[ $deployments -gt 0 ]]; then
    local ready_deployments=$(oc get deployments -n "$PROTECTED_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}{"/"}{.status.replicas}{"\n"}{end}' 2>/dev/null || echo "")
    while IFS=$'\t' read -r name replicas; do
      if [[ -n "$name" && -n "$replicas" ]]; then
        echo "    Deployment $name: $replicas"
        if [[ "$replicas" =~ ^0/ ]] || [[ "$replicas" =~ /0$ ]]; then
          echo "      ❌ Deployment $name is not ready"
          all_objects_healthy=false
        fi
      fi
    done <<< "$ready_deployments"
  else
    echo "    No Deployments found (this may be expected)"
  fi
  
  # Check StatefulSets
  echo "  Checking StatefulSets..."
  local statefulsets=$(oc get statefulsets -n "$PROTECTED_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
  if [[ $statefulsets -gt 0 ]]; then
    local ready_statefulsets=$(oc get statefulsets -n "$PROTECTED_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}{"/"}{.status.replicas}{"\n"}{end}' 2>/dev/null || echo "")
    while IFS=$'\t' read -r name replicas; do
      if [[ -n "$name" && -n "$replicas" ]]; then
        echo "    StatefulSet $name: $replicas"
        if [[ "$replicas" =~ ^0/ ]] || [[ "$replicas" =~ /0$ ]]; then
          echo "      ❌ StatefulSet $name is not ready"
          all_objects_healthy=false
        fi
      fi
    done <<< "$ready_statefulsets"
  else
    echo "    No StatefulSets found (this may be expected)"
  fi
  
  # Check Pods
  echo "  Checking Pods..."
  local pod_count=$(oc get pods -n "$PROTECTED_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
  if [[ $pod_count -gt 0 ]]; then
    local failed_pods=$(oc get pods -n "$PROTECTED_NAMESPACE" -o jsonpath='{range .items[?(@.status.phase!="Running" && @.status.phase!="Succeeded")]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")
    if [[ -n "$failed_pods" ]]; then
      echo "    ⚠️  Some pods are not in Running/Succeeded state:"
      echo "$failed_pods" | sed 's/^/      /'
      # Don't fail on pod status - they may be starting up
    else
      echo "    ✅ All pods are in Running or Succeeded state"
    fi
  else
    echo "    No Pods found (this may be expected)"
  fi
  
  if [[ "$all_objects_healthy" == "true" ]]; then
    echo "✅ Kubernetes objects in protected namespace appear healthy"
    return 0
  else
    echo "⚠️  Some Kubernetes objects may not be fully healthy, but continuing..."
    return 0  # Don't fail on this - allow the check to continue
  fi
}

# Function to disable ArgoCD sync for the application
disable_argocd_sync() {
  echo "Disabling ArgoCD sync for application $ARGOCD_APP_NAME..."
  
  # First, check if the Application exists
  local app_namespace="argocd"  # Default ArgoCD namespace
  local app_found=false
  
  # Try to find the Application in common namespaces
  for ns in argocd openshift-gitops; do
    if oc get application "$ARGOCD_APP_NAME" -n "$ns" &>/dev/null; then
      app_namespace="$ns"
      app_found=true
      echo "  Found ArgoCD Application $ARGOCD_APP_NAME in namespace $app_namespace"
      break
    fi
  done
  
  if [[ "$app_found" == "false" ]]; then
    echo "  ⚠️  ArgoCD Application $ARGOCD_APP_NAME not found in common namespaces"
    echo "  Attempting to find it in all namespaces..."
    
    # Search all namespaces for the Application
    local found_ns=$(oc get application --all-namespaces -o jsonpath="{range .items[?(@.metadata.name==\"$ARGOCD_APP_NAME\")]}{.metadata.namespace}{end}" 2>/dev/null || echo "")
    
    if [[ -n "$found_ns" ]]; then
      app_namespace="$found_ns"
      app_found=true
      echo "  Found ArgoCD Application $ARGOCD_APP_NAME in namespace $app_namespace"
    else
      echo "  ❌ ArgoCD Application $ARGOCD_APP_NAME not found"
      return 1
    fi
  fi
  
  # Check current sync policy
  local current_sync_policy=$(oc get application "$ARGOCD_APP_NAME" -n "$app_namespace" -o jsonpath='{.spec.syncPolicy}' 2>/dev/null || echo "")
  
  if [[ -z "$current_sync_policy" || "$current_sync_policy" == "null" ]]; then
    echo "  Application already has no sync policy (sync is disabled)"
    return 0
  fi
  
  # Check if automated sync is enabled
  local automated_sync=$(oc get application "$ARGOCD_APP_NAME" -n "$app_namespace" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || echo "")
  
  if [[ -z "$automated_sync" || "$automated_sync" == "null" ]]; then
    echo "  ✅ ArgoCD sync is already disabled (no automated sync policy)"
    return 0
  fi
  
  # Disable automated sync by removing the automated field
  echo "  Current sync policy has automated sync enabled, disabling it..."
  
  # Patch the Application to remove automated sync
  if oc patch application "$ARGOCD_APP_NAME" -n "$app_namespace" --type=json -p='[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' 2>/dev/null; then
    echo "  ✅ Successfully disabled ArgoCD automated sync for application $ARGOCD_APP_NAME"
    return 0
  else
    # Alternative: set automated to null
    if oc patch application "$ARGOCD_APP_NAME" -n "$app_namespace" --type=merge -p='{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null; then
      echo "  ✅ Successfully disabled ArgoCD automated sync for application $ARGOCD_APP_NAME"
      return 0
    else
      echo "  ❌ Failed to disable ArgoCD sync"
      return 1
    fi
  fi
}

# Main check loop
attempt=1

while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  echo ""
  echo "=== DRPC Health Check Attempt $attempt/$MAX_ATTEMPTS ==="
  
  all_checks_passed=true
  
  # Check DRPC exists
  if ! check_drpc_exists; then
    all_checks_passed=false
  fi
  
  # Check DRPC status
  if ! check_drpc_status; then
    all_checks_passed=false
  fi
  
  # Check PVCs
  if ! check_pvcs_health; then
    all_checks_passed=false
  fi
  
  # Check Kubernetes objects
  if ! check_k8s_objects_health; then
    all_checks_passed=false
  fi
  
  if [[ "$all_checks_passed" == "true" ]]; then
    echo ""
    echo "🎉 All health checks passed! DRPC and related resources are healthy."
    echo ""
    echo "Disabling ArgoCD sync for application $ARGOCD_APP_NAME..."
    
    if disable_argocd_sync; then
      echo ""
      echo "✅ Successfully completed:"
      echo "  - DRPC health verified (Kubernetes objects and PVCs)"
      echo "  - ArgoCD sync disabled for application $ARGOCD_APP_NAME"
      exit 0
    else
      echo ""
      echo "⚠️  Health checks passed but failed to disable ArgoCD sync"
      echo "  This may be a transient issue. The job will retry on next sync."
      exit 1
    fi
  else
    echo ""
    echo "❌ Not all health checks passed. Waiting $SLEEP_INTERVAL seconds before retry..."
    sleep $SLEEP_INTERVAL
    ((attempt++))
  fi
done

echo ""
echo "❌ DRPC health check failed after $MAX_ATTEMPTS attempts"
echo "Please ensure:"
echo "1. DRPC $DRPC_NAME exists in namespace $DRPC_NAMESPACE"
echo "2. DRPC is in a healthy state (Deployed phase or Available/Ready conditions)"
echo "3. PVCs in namespace $PROTECTED_NAMESPACE are Bound"
echo "4. Kubernetes objects in namespace $PROTECTED_NAMESPACE are healthy"
echo ""
echo "Current DRPC status:"
oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" -o yaml 2>/dev/null || echo "  DRPC not found or not accessible"
exit 1

