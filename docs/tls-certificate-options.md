# TLS Certificate Configuration Options

This document explains the different options for configuring TLS certificates for Keycloak JWT validation.

## Overview

The Cost Management On-Premise Helm chart needs to validate JWT tokens from Keycloak. This requires trusting Keycloak's TLS certificate. There are multiple ways to configure this.

## Option 1: Automatic Certificate Fetching

**Recommended for: Local/In-Cluster Keycloak on OpenShift**

### How it works:
- OpenShift automatically injects ingress CA via service CA injection
- Init container dynamically fetches Keycloak's certificate chain on pod startup
- Works with self-signed certificates, intermediate CAs, and public CAs
- Certificate is fetched fresh on each pod restart

### Configuration:

**For Local/In-Cluster Keycloak (OpenShift):**
```yaml
# No configuration needed at all!
# Keycloak URL, CA, and namespace are all auto-discovered
```

**For External Keycloak (Different Cluster):**
```yaml
jwt_auth:
  keycloak:
    url: "https://keycloak.external-company.com"
    realm: "production"
    # CA will be dynamically fetched (requires network egress)
```

### Advantages:
- ✅ Zero configuration for local Keycloak on OpenShift
- ✅ Handles certificate rotation automatically
- ✅ Fetches entire certificate chain (including intermediates)
- ✅ Easiest to deploy in new environments

### Requirements for External Keycloak:
- ⚠️ Pods must have network egress to external Keycloak
- ⚠️ DNS must resolve external hostname
- ⚠️ External Keycloak must be accessible during pod startup

### When to use:
- **Local Keycloak on OpenShift** (always recommended)
- External Keycloak with unrestricted egress
- Development/testing environments

---

## Option 2: Manual Certificate Configuration

**Recommended for: External Keycloak, Air-gapped, Production**

### How it works:
- You provide the CA certificate manually in `values.yaml`
- The certificate is embedded in the Helm chart
- No network connection to Keycloak needed during pod startup

### Configuration:

```yaml
jwt_auth:
  keycloak:
    # REQUIRED for external Keycloak
    url: "https://keycloak.external-company.com"
    realm: "production"
    tls:
      caCert: |
        -----BEGIN CERTIFICATE-----
        MIIDXTCCAkWgAwIBAgIJAKLnUhVP3GVDMA0GCSqGSIb3DQEBCwUAMEUxCzAJBgNV
        ... your certificate content ...
        -----END CERTIFICATE-----
```

### How to get the certificate:

```bash
# From external Keycloak (run from your local machine or bastion)
echo | openssl s_client -connect keycloak.external-company.com:443 -showcerts 2>/dev/null | \
  openssl x509 -outform PEM > keycloak-ca.crt

# Verify it's valid
openssl x509 -in keycloak-ca.crt -noout -text

# Copy the contents into values.yaml
cat keycloak-ca.crt
```

### Advantages:
- ✅ **No external dependency during pod startup** (critical for external Keycloak)
- ✅ Works in air-gapped environments
- ✅ No egress NetworkPolicy requirements
- ✅ Predictable behavior
- ✅ Faster pod initialization
- ✅ Deployment doesn't depend on external service availability

### Disadvantages:
- ❌ Requires manual configuration
- ❌ Must update values.yaml when certificate rotates
- ❌ Must include entire chain for intermediate CAs

### When to use:
- **External Keycloak (different cluster)** - STRONGLY RECOMMENDED
- Air-gapped environments
- Strict security policies requiring static configuration
- Production environments with controlled change management
- When egress NetworkPolicies block external access
- When DNS cannot resolve external Keycloak

---

## Option 3: Disable TLS Validation (Development Only)

**⚠️ NOT RECOMMENDED FOR PRODUCTION**

### How it works:
- Skips TLS certificate validation entirely
- Envoy will accept any certificate from Keycloak

### Configuration:

```yaml
jwt_auth:
  keycloak:
    url: "https://keycloak.example.com"
  envoy:
    skipTlsVerify: true  # INSECURE!
```

### Security implications:
- ⚠️ Vulnerable to Man-in-the-Middle attacks
- ⚠️ Anyone can impersonate Keycloak
- ⚠️ JWT validation can be bypassed

### When to use:
- Local development only
- Testing environments
- **NEVER in production**

---

## Option 4: System CA Bundle Only

**For environments where Keycloak uses a publicly trusted CA.**

### How it works:
- Uses only the system CA bundle (no Keycloak-specific certificate)
- Works if Keycloak certificate is signed by a public CA (Let's Encrypt, DigiCert, etc.)

### Configuration:

```yaml
jwt_auth:
  keycloak:
    url: "https://keycloak.example.com"
    # No tls configuration needed
```

### Additional setup:
Set the `skipKeycloakCaFetch` flag to prevent dynamic fetching:

```yaml
jwt_auth:
  keycloak:
    tls:
      skipDynamicFetch: true  # Only use system CAs
```

### Advantages:
- ✅ No configuration needed
- ✅ Works automatically with public CAs
- ✅ Certificate rotation handled by OS/image updates

### When to use:
- Keycloak uses Let's Encrypt or other public CA
- Keycloak certificate is in the OS trust store

---

## Troubleshooting

### How to verify which method is being used:

Check the init container logs:

```bash
kubectl logs -n cost-mgmt <pod-name> -c prepare-ca-bundle
```

You'll see one of:
- `"Adding manually provided Keycloak CA..."` - Option 2 (manual)
- `"Successfully fetched Keycloak certificate chain..."` - Option 1 (automatic)
- `"No custom CA certificate provided..."` - Option 1 (automatic)

### Common issues:

**1. "Failed to validate fetched certificate"**
- Keycloak endpoint is not accessible from pods
- Self-signed certificate with missing chain
- Solution: Use Option 2 (manual configuration)

**2. "Invalid CA certificate in values.yaml"**
- Provided certificate is corrupted or incomplete
- Solution: Verify certificate format and content

**3. "Could not connect to Keycloak"**
- Network policy blocking egress
- Keycloak service down
- Solution: Check network connectivity or use Option 2

### Testing certificate validation:

```bash
# Test from inside a pod
kubectl exec -n cost-mgmt <pod-name> -c envoy-proxy -- \
  curl -s http://localhost:9901/clusters | grep keycloak_jwks

# Check for:
# - rq_success: >0  (successful JWKS fetches)
# - rq_error: 0     (no errors)
# - health_flags: healthy
```

---

## Recommendation Summary

| Scenario | Recommended Option | Configuration Required | Why |
|----------|-------------------|------------------------|-----|
| **Local Keycloak (OpenShift)** | Option 1 (Auto) | **None!** | Zero config, OpenShift handles CA injection |
| **External Keycloak (Prod)** | Option 2 (Manual CA) | URL + CA cert | No external dependency during startup |
| **External Keycloak (Dev/Test)** | Option 1 (Auto) | URL only | Simpler, egress usually allowed |
| **Public CA (Let's Encrypt)** | Option 4 (System CA) | URL only | System CA already trusted |
| **Air-gapped** | Option 2 (Manual) | URL + CA cert | No network access to external services |
| **Testing only** | Option 3 (Skip TLS) | Skip flag | Fast iteration, **not secure** |

**Default for OpenShift with Local Keycloak:** Option 1 (automatic) - zero configuration required

**Default for External Keycloak:** Option 2 (manual CA) - explicit URL and CA certificate strongly recommended

See [external-keycloak-scenario.md](./external-keycloak-scenario.md) for detailed analysis of external Keycloak architecture and troubleshooting.

