# PR Summary: Migration from OpenShift OAuth Proxy to Keycloak OAuth2 Proxy

## Overview
This PR migrates the authentication system from OpenShift OAuth Proxy to Keycloak OAuth2 Proxy, providing a more flexible and configurable authentication solution that works across different Kubernetes platforms. **Authorino has been removed** and replaced with **direct Envoy JWT validation in the ROS API**, simplifying the authentication architecture and reducing dependencies.

## Key Changes

### 🔐 Authentication Migration
- **Replaced OpenShift OAuth Proxy with Keycloak OAuth2 Proxy**
  - Migrated UI authentication from OpenShift-specific OAuth proxy to Keycloak OAuth2 proxy
  - **Removed Authorino** - No longer using Authorino for JWT validation
  - **ROS API now uses Envoy directly** for Keycloak JWT token validation
  - Updated ROS API Envoy configuration to validate Keycloak JWT tokens natively
  - Removed all Authorino dependencies, CRDs, and related documentation

### 🧪 Testing & Scripts
- **Updated test script** (`test-ocp-dataflow-jwt.sh`)
  - Modified to work with Keycloak OAuth flow instead of OpenShift OAuth
  - Streamlined authentication flow for Keycloak integration

### 🔑 Keycloak Configuration
- **Added Cost Management UI client to Keycloak realm**
  - Created `cost-management-ui` client in the Kubernetes realm via `deploy-rhbk.sh`
  - Configured with proper redirect URIs and web origins for OAuth2 flow
  - Client supports authorization code flow with appropriate scopes

- **Added test user and group**
  - Created `test-group` with `org_id` attribute set to `12345`
  - Created `test` user with:
    - Password: `test`
    - Email: `test@test.com` (verified)
    - Group membership: `test-group`
  - Automated creation integrated into RHBK deployment script

### ⚙️ Configuration Improvements
- **Enhanced Nginx ConfigMap**
  - Added `nginx-config.yaml` ConfigMap for UI nginx configuration
  - Made nginx configuration more configurable and maintainable
  - Improved proxy settings for API and inspect endpoints

- **Updated Secret Management**
  - UI OAuth client secret now stores both `client-id` and `client-secret`
  - Improved secret lookup and fallback mechanisms
  - Better integration with Helm values for client credentials

### 📝 Documentation & Cleanup
- Removed Authorino-related documentation and CRDs
- Updated installation and configuration guides
- Cleaned up obsolete authentication references

## Technical Details

### Files Changed
- `cost-onprem/templates/ui/deployment.yaml` - Updated to use Keycloak OAuth2 proxy
- `cost-onprem/templates/ui/secret.yaml` - Enhanced to store client-id and client-secret
- `cost-onprem/templates/ui/nginx-config.yaml` - New configurable nginx configuration
- `cost-onprem/templates/ros/api/envoy-config.yaml` - **Updated to use Envoy directly for Keycloak JWT validation** (replacing Authorino)
- `cost-onprem/templates/ros/api/deployment.yaml` - Updated to remove Authorino dependencies
- `scripts/deploy-rhbk.sh` - Added UI client creation and test user/group setup
- `scripts/test-ocp-dataflow-jwt.sh` - Updated for Keycloak authentication flow
- `scripts/install-helm-chart.sh` - Enhanced to pass Keycloak client configuration
- **Removed**: All Authorino templates, CRDs, and related authentication components

## Migration Notes
- Existing deployments will need to be updated with Keycloak client credentials
- The `deploy-rhbk.sh` script now automatically creates the UI client and test resources
- Client secrets are stored in Kubernetes secrets for secure access

## Testing
- Test script updated to validate Keycloak OAuth flow
- Test user and group available for integration testing
- All authentication flows verified with Keycloak JWT tokens

