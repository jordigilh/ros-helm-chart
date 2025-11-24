#!/bin/bash

# Kafka Topics Deployment Script for Cost Management
# This script creates Kafka topics required by the Koku cost management service
#
# PREREQUISITE: Kafka must be deployed first (via deploy-strimzi.sh)
#
# Usage:
#   ./deploy-kafka-topics-cost-mgmt.sh

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KAFKA_NAMESPACE=${KAFKA_NAMESPACE:-kafka}
KAFKA_CLUSTER_NAME=${KAFKA_CLUSTER_NAME:-ros-ocp-kafka}
REPLICATION_FACTOR=${REPLICATION_FACTOR:-1}  # 1 for dev, 3 for production

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# Function to detect platform (Kubernetes vs OpenShift)
detect_platform() {
    echo_info "Detecting platform..."

    if kubectl get routes.route.openshift.io >/dev/null 2>&1; then
        echo_success "Detected OpenShift platform"
        # Use higher replication factor for OpenShift/production
        if [ "$REPLICATION_FACTOR" = "1" ]; then
            REPLICATION_FACTOR=3
            echo_info "Auto-set replication factor to 3 for OpenShift"
        fi
    else
        echo_success "Detected Kubernetes platform"
    fi
}

# Function to create Kafka topic
create_topic() {
    local topic_name="$1"
    local partitions="${2:-3}"
    local replication="${3:-$REPLICATION_FACTOR}"

    # Check if topic already exists
    if kubectl get kafkatopic "$topic_name" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        echo_info "Topic '$topic_name' already exists, skipping"
        return 0
    fi

    echo_info "Creating topic: $topic_name (partitions: $partitions, replication: $replication)"

    # Create topic YAML
    cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: $topic_name
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: $KAFKA_CLUSTER_NAME
    app: cost-management
spec:
  partitions: $partitions
  replicas: $replication
  config:
    retention.ms: "604800000"  # 7 days
    segment.ms: "86400000"      # 1 day
    cleanup.policy: "delete"
EOF

    if [ $? -eq 0 ]; then
        echo_success "✓ Topic '$topic_name' created"
        return 0
    else
        echo_warning "Failed to create topic '$topic_name'"
        return 1
    fi
}

# Main execution
main() {
    echo_header "COST MANAGEMENT KAFKA TOPICS DEPLOYMENT"

    # Check prerequisites
    if ! command -v kubectl >/dev/null 2>&1; then
        echo_error "kubectl command not found. Please install kubectl."
        exit 1
    fi

    if ! kubectl get nodes >/dev/null 2>&1; then
        echo_error "Cannot connect to cluster. Please check your kubectl configuration."
        exit 1
    fi

    # Detect platform
    detect_platform

    # Check if Kafka cluster exists
    if ! kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        echo_error "Kafka cluster '$KAFKA_CLUSTER_NAME' not found in namespace '$KAFKA_NAMESPACE'"
        echo_error "Please run './deploy-strimzi.sh' first to deploy Kafka"
        exit 1
    fi

    echo_info "Kafka cluster found: $KAFKA_CLUSTER_NAME"
    echo_info "Replication factor: $REPLICATION_FACTOR"
    echo ""

    # Cost Management Kafka Topics
    # Based on ../koku/deploy/clowdapp.yaml kafkaTopics section
    echo_header "CREATING COST MANAGEMENT TOPICS"

    # Topic definitions: "topic_name:partitions:replication_factor"
    local topics=(
        # Platform topics (shared with other services)
        "platform.upload.announce:3:$REPLICATION_FACTOR"           # Payload upload notifications
        "platform.upload.validation:3:$REPLICATION_FACTOR"         # Payload validation results
        "platform.sources.event-stream:3:$REPLICATION_FACTOR"      # Sources API events
        "platform.notifications.ingress:3:$REPLICATION_FACTOR"     # Notifications ingress

        # Cost Management specific topics
        "hccm.ros.events:3:$REPLICATION_FACTOR"                    # ROS integration events
        "platform.rhsm-subscriptions.service-instance-ingress:3:$REPLICATION_FACTOR"  # RHSM subscriptions
    )

    local created=0
    local skipped=0
    local failed=0

    for topic_config in "${topics[@]}"; do
        IFS=':' read -r topic_name partitions replication <<< "$topic_config"

        if create_topic "$topic_name" "$partitions" "$replication"; then
            if kubectl get kafkatopic "$topic_name" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
                created=$((created + 1))
            else
                skipped=$((skipped + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo_header "DEPLOYMENT SUMMARY"
    echo_info "Topics created: $created"
    echo_info "Topics skipped (already exist): $skipped"
    if [ $failed -gt 0 ]; then
        echo_warning "Topics failed: $failed"
    fi
    echo ""

    # List all topics
    echo_info "All Cost Management topics:"
    kubectl get kafkatopic -n "$KAFKA_NAMESPACE" -l app=cost-management -o custom-columns=NAME:.metadata.name,PARTITIONS:.spec.partitions,REPLICAS:.spec.replicas,READY:.status.conditions[0].status 2>/dev/null || true
    echo ""

    echo_success "Cost Management Kafka topics deployment completed!"
    echo ""
    echo_info "Verification:"
    echo_info "  kubectl get kafkatopic -n $KAFKA_NAMESPACE -l app=cost-management"
}

# Run main function
main

