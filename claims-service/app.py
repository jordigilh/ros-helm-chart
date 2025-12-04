#!/usr/bin/env python3
"""
Claims Metadata Service
Provides custom user claims for Authorino authentication
"""
from flask import Flask, jsonify, request
from flask_caching import Cache
import requests
import logging
import os
import sys

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger(__name__)

# Configuration from environment
KEYCLOAK_URL = os.getenv('KEYCLOAK_URL', 'https://keycloak-keycloak.apps.stress.parodos.dev')
REALM = os.getenv('REALM', 'kubernetes')
ADMIN_USERNAME = os.getenv('ADMIN_USERNAME', 'admin')
ADMIN_PASSWORD = os.getenv('ADMIN_PASSWORD', '')

# Cache configuration - simple in-memory cache
cache_config = {
    'CACHE_TYPE': 'simple',
    'CACHE_DEFAULT_TIMEOUT': 300  # 5 minutes
}
app.config.from_mapping(cache_config)
cache = Cache(app)


class KeycloakClient:
    """Keycloak Admin API client with token caching"""
    
    def __init__(self):
        self.admin_token = None
        self.token_expires_at = 0
    
    def get_admin_token(self):
        """Get admin access token with automatic refresh"""
        import time
        
        # Return cached token if still valid (with 60s buffer)
        if self.admin_token and time.time() < (self.token_expires_at - 60):
            return self.admin_token
        
        logger.info("Fetching new Keycloak admin token")
        token_url = f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
        
        try:
            response = requests.post(
                token_url,
                data={
                    'username': ADMIN_USERNAME,
                    'password': ADMIN_PASSWORD,
                    'grant_type': 'password',
                    'client_id': 'admin-cli'
                },
                verify=False,  # For dev/testing - use proper certs in production
                timeout=10
            )
            response.raise_for_status()
            
            token_data = response.json()
            self.admin_token = token_data['access_token']
            self.token_expires_at = time.time() + token_data.get('expires_in', 300)
            
            logger.info("Admin token obtained successfully")
            return self.admin_token
            
        except requests.RequestException as e:
            logger.error(f"Failed to get admin token: {e}")
            raise
    
    def get_user_by_username(self, username):
        """Fetch user details from Keycloak by username"""
        token = self.get_admin_token()
        users_url = f"{KEYCLOAK_URL}/admin/realms/{REALM}/users"
        
        headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json'
        }
        params = {
            'username': username,
            'exact': 'true'
        }
        
        try:
            logger.debug(f"Querying Keycloak for user: {username}")
            response = requests.get(
                users_url,
                headers=headers,
                params=params,
                verify=False,
                timeout=10
            )
            response.raise_for_status()
            
            users = response.json()
            if users:
                logger.debug(f"Found user: {username}")
                return users[0]
            else:
                logger.warning(f"User not found in Keycloak: {username}")
                return None
                
        except requests.RequestException as e:
            logger.error(f"Keycloak API error: {e}")
            raise
    
    def get_user_groups(self, user_id):
        """Fetch user's group memberships from Keycloak"""
        token = self.get_admin_token()
        groups_url = f"{KEYCLOAK_URL}/admin/realms/{REALM}/users/{user_id}/groups"
        
        headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json'
        }
        
        try:
            response = requests.get(
                groups_url,
                headers=headers,
                verify=False,
                timeout=10
            )
            response.raise_for_status()
            return response.json()
            
        except requests.RequestException as e:
            logger.error(f"Failed to get user groups: {e}")
            return []


# Initialize Keycloak client
keycloak_client = KeycloakClient()


@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": "claims-service",
        "version": "1.0.0"
    }), 200


@app.route('/ready')
def ready():
    """Readiness check - verify Keycloak connectivity"""
    try:
        # Try to get an admin token to verify connectivity
        keycloak_client.get_admin_token()
        return jsonify({
            "status": "ready",
            "keycloak": "connected"
        }), 200
    except Exception as e:
        logger.error(f"Readiness check failed: {e}")
        return jsonify({
            "status": "not ready",
            "error": str(e)
        }), 503


@app.route('/claims/<username>')
@cache.cached(timeout=300, key_prefix='claims_%s')
def get_claims(username):
    """
    Fetch custom claims for a user.
    
    This endpoint is cached for 5 minutes per user by Flask-Caching.
    Authorino will also cache the response for additional performance.
    
    Returns:
        JSON with custom claims:
        {
            "org_id": "1234567",
            "account_number": "7890123",
            "email": "user@example.com",
            "groups": ["group1", "group2"]
        }
    """
    logger.info(f"Fetching claims for user: {username}")
    
    try:
        # Get user from Keycloak
        user = keycloak_client.get_user_by_username(username)
        
        if not user:
            logger.warning(f"User not found: {username}")
            return jsonify({
                "error": "User not found",
                "username": username
            }), 404
        
        # Get user groups
        groups = keycloak_client.get_user_groups(user['id'])
        group_names = [g['name'] for g in groups]
        
        # Extract custom attributes from Keycloak user
        # These can be set via Keycloak Admin UI or API
        attributes = user.get('attributes', {})
        
        # Helper function to get first value from attribute array
        def get_attr(key, default=None):
            values = attributes.get(key, [default] if default else [])
            return values[0] if values else default
        
        # Extract org_id from group name as fallback
        # Format: "cost_management_organization_id_1234567"
        org_id_from_group = None
        for group in group_names:
            if group.startswith('cost_management_organization_id_'):
                org_id_from_group = group.replace('cost_management_organization_id_', '')
                break
        
        # Build claims response
        claims = {
            "user_id": user['id'],
            "username": user['username'],
            "email": user.get('email'),
            "first_name": user.get('firstName'),
            "last_name": user.get('lastName'),
            "groups": group_names,
            # Custom claims - prefer attributes, fallback to group parsing
            "org_id": get_attr('org_id', org_id_from_group),
            "account_number": get_attr('account_number'),
            "customer_type": get_attr('customer_type', 'standard'),
            "entitlements": get_attr('entitlements', '').split(',') if get_attr('entitlements') else []
        }
        
        logger.info(f"Claims retrieved for {username}: org_id={claims['org_id']}, "
                   f"account={claims['account_number']}")
        
        return jsonify(claims), 200
        
    except requests.HTTPError as e:
        logger.error(f"Keycloak API HTTP error for user {username}: {e}")
        return jsonify({
            "error": "Failed to fetch user data",
            "details": str(e)
        }), 502
        
    except Exception as e:
        logger.error(f"Unexpected error fetching claims for {username}: {e}", exc_info=True)
        return jsonify({
            "error": "Internal server error",
            "details": str(e)
        }), 500


@app.route('/cache/clear', methods=['POST'])
def clear_cache():
    """
    Clear all cached claims.
    Admin endpoint - should be secured in production.
    """
    cache.clear()
    logger.info("Cache cleared")
    return jsonify({"status": "cache cleared"}), 200


@app.route('/cache/clear/<username>', methods=['POST'])
def clear_user_cache(username):
    """
    Clear cached claims for a specific user.
    Useful after updating user attributes in Keycloak.
    """
    cache.delete(f'claims_{username}')
    logger.info(f"Cache cleared for user: {username}")
    return jsonify({"status": "cache cleared", "username": username}), 200


if __name__ == '__main__':
    # Development server
    # In production, use gunicorn (see Dockerfile)
    app.run(host='0.0.0.0', port=8080, debug=False)

