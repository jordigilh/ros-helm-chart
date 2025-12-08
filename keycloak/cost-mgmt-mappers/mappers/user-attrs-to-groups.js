// Cost Management Protocol Mapper
// Reads user LDAP attributes and injects them as synthetic groups in the JWT

// Read configuration from realm attributes (set per customer via Keycloak admin)
var realmAttrs = realm.getAttributes();

// Config keys are hardcoded, but values are configurable per realm
var orgAttrName = realmAttrs.get("cost-mgmt-org-attr");
var accountAttrName = realmAttrs.get("cost-mgmt-account-attr");

// Provide defaults if not configured
if (orgAttrName == null || orgAttrName.isEmpty()) {
    orgAttrName = "costCenter";
}
if (accountAttrName == null || accountAttrName.isEmpty()) {
    accountAttrName = "accountNumber";
}

// Read user's LDAP attributes using configured names
// Use getFirstAttribute() - the correct Keycloak API
var orgId = user.getFirstAttribute(orgAttrName);
var accountNumber = user.getFirstAttribute(accountAttrName);

// Get existing groups from token
var groups = token.getOtherClaims().get("groups");
if (groups == null) {
    groups = new java.util.ArrayList();
}

// Add synthetic groups for cost management
if (orgId != null && !orgId.isEmpty()) {
    groups.add("cost-mgmt-org-" + orgId);
}
if (accountNumber != null && !accountNumber.isEmpty()) {
    groups.add("cost-mgmt-account-" + accountNumber);
}

token.getOtherClaims().put("groups", groups);
"OK";
