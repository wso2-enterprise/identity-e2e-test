# API Test Suite for IAM Products

**Target Products**: WSO2 Identity Server & Asgardeo
**Tool Used**: Postman + Newman

# Introduction
This repository contains an automated API testing suite for WSO2 Identity Server and Asgardeo, aimed at improving test efficiency, reducing test time, and ensuring better API reliability, especially where UI-based testing is time-consuming.

# Scope
This test suite focuses on comprehensive backend-level API validation for WSO2 Identity Server and Asgardeo. The primary goal is to ensure correctness, security, and stability of all exposed API endpoints critical to Identity and Access Management.

**Key Areas Covered:**
1. Authentication & Authorization
2. Token generation and validation
3. Session and consent management
4. OAuth2/OpenID Connect flows
5. SCIM (User & Role Management)
6. User creation, update, deletion
7. Role assignment and group management
8. Attribute-level access validation
9. Application Management
10. Registering and configuring service providers
11. Application update and deletion workflows
12. SAML/OIDC configurations

**Other Core APIs as listed in the WSO2 Identity Server latest API documentation including:**

1. Identity Provider APIs
2. Consent Management
3. Tenant Management
4. Claim Management
5. Account Recovery and Self-Service APIs

# Key Objectives

1. Validate API response structure and error handling
2. Automate regression checks using Postman and Newman
3. Enable CI/CD-ready test execution
4. Generate detailed HTML test reports
5. Improve developer support and test scalability

# Implementation Overview
1. Workspace Setup
Postman collections created and executed using Postman app

Environment variables to be added for token management and API base URLs

2. API Collections
Grouped by functional modules:

  Authentication (OAuth)
  SCIM v2 APIs (Users, Groups, Roles)
  Applications (App lifecycle)
  Test scripts include JavaScript validations (status codes, response data)

3. Test Execution
Use Newman CLI for running collections:

```
newman run collection.json -k

```
4. CI/CD Integration
GitHub Actions workflow includes:

Starting WSO2 Identity Server (build or Docker)

Running Newman CLI tests

Uploading test artifacts and HTML reports

5. Reporting
Newman generates:

Detailed CLI output

HTML reports for summary & debugging

6. Maintenance
Test cases stored in Git repo with version control

Test suite designed for modularity and easy scaling

Regular updates to match API spec changes


