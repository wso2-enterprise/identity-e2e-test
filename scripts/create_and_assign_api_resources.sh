#!/bin/bash

# Check if server URL is provided as an environment variable
SERVER_URL=${SERVER_URL:-"localhost:9443"}

# Remove trailing slash if present
SERVER_URL=${SERVER_URL%/}
echo "Using WSO2 Identity Server at: ${SERVER_URL}"

# Base URLs
BASE_URL_API_RESOURCES="https://${SERVER_URL}/t/carbon.super/api/server/v1/api-resources"
BASE_URL_CREATE_APP="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications"
BASE_URL_GET_APP_ID="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications?filter=name+eq+E2E-Test-Suite-Token"
BASE_URL_ASSIGN_APIS="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications/%s/authorized-apis"  # Placeholder for app ID

# Admin credentials
USERNAME='admin'
PASSWORD='admin'

# Create the Authorization header
AUTH=$(echo "$USERNAME:$PASSWORD" | base64)

# Output file to store all API resources
OUTPUT_FILE="api_resources.json"

# Clear the output file before starting
> "$OUTPUT_FILE"

# Function to create the application
create_application() {
    echo "Creating application 'E2E-Test-Suite-Token'..."

    create_app_response=$(curl --silent --insecure --location "$BASE_URL_CREATE_APP" \
        --header "Authorization: Basic $AUTH" \
        --header 'Content-Type: application/json' \
        --data-raw '{
            "name": "E2E-Test-Suite-Token",
            "advancedConfigurations": {
                "skipLogoutConsent": true,
                "skipLoginConsent": true
            },
            "templateId": "custom-application-oidc",
            "associatedRoles": {
                "allowedAudience": "APPLICATION",
                "roles": []
            },
            "inboundProtocolConfiguration": {
                "oidc": {
                    "grantTypes": ["client_credentials"],
                    "isFAPIApplication": false
                }
            }
        }')

    echo "Response from application creation:"
    echo "$create_app_response"
}

# Function to get the application ID
get_application_id() {
    echo "Fetching the application ID for 'E2E-Test-Suite-Token'..."

    get_app_response=$(curl --silent --insecure --location "$BASE_URL_GET_APP_ID" \
        --header "Authorization: Basic $AUTH" \
        --header 'Accept: application/json')

    # Parse the application ID from the response
    app_id=$(echo "$get_app_response" | jq -r '.applications[0].id')

    if [[ "$app_id" == "null" || -z "$app_id" ]]; then
        echo "Failed to find the application ID."
        exit 1
    else
        echo "Application ID: $app_id"
        echo "$app_id" > app_id.txt  # Save the app ID for further use
    fi
}

# Function to fetch and process the API resources
fetch_api_resources() {
    local url=$1
    local app_id=$2

    # Make the API request using basic auth in the header
    response=$(curl --location --insecure -s "$url" \
        -H "Authorization: Basic $AUTH" \
        -H "Accept: application/json")

    # Log the response for debugging
    echo "Response from fetching resources:"
    echo "$response"  # Log raw response for inspection

    # Check if the response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo "Error: Invalid JSON response. Please check the API endpoint and response."
        echo "$response"  # Log the raw response for inspection
        return
    fi

    # Extract the "apiResources" from the response and process them
    echo "$response" | jq -c '.apiResources[]' | while read -r resource; do
        resource_id=$(echo "$resource" | jq -r '.id')
        resource_self=$(echo "$resource" | jq -r '.self')
        scope_url="https://${SERVER_URL}$resource_self"
        
        # Check if the resource_id is valid
        if [[ "$resource_id" != "null" && "$resource_id" != "" ]]; then
            # Prepare the scopes for the current resource
            # declare -a scopes=("internal_notifications_view" "internal_notifications_create" "internal_notifications_update" "internal_notifications_delete")

            scopes_list=$(curl --location --request GET --insecure -s "$scope_url" \
                -H "Authorization: Basic $AUTH")

            scopes=$(echo "$scopes_list" | jq -r '.scopes | map(.name)')
            echo "=================================================================================================="
            echo $scopes
            echo "=================================================================================================="
            # Create JSON for the resource with updated scopes
            resource_json=$(jq -n --arg id "$resource_id" \
                                 --arg policyIdentifier "RBAC" \
                                 --argjson scopes "$scopes" \
                                 '{"id": $id, "policyIdentifier": $policyIdentifier, "scopes": $scopes}')

            assign_url=$(printf "$BASE_URL_ASSIGN_APIS" "$app_id")

            # Make the API request to assign the resource
            assign_response=$(curl --location --request POST --insecure -s "$assign_url" \
                -H "Authorization: Basic $AUTH" \
                -H 'Content-Type: application/json' \
                --data-raw "$resource_json")
    echo "Assigning resource to application $app_id: $resource_json via url $assign_url"
                # Log the response for debugging
                echo "Response from assigning API resource:"
                echo "$assign_response"

                # Append to OUTPUT_FILE
                echo "$resource_json" >> "$OUTPUT_FILE"
            else
                echo "Skipping empty resource ID."
            fi
        done

        # Check if there is a "next" link for pagination
        next_url=$(echo "$response" | jq -r '.links[]? | select(.rel=="next") | .href')

        if [[ "$next_url" != "" && "$next_url" != "null" ]]; then
            echo "Fetching next page: $next_url"
            fetch_api_resources "$next_url" "$app_id"  # Recursively fetch the next page
        fi
    }

# Function to assign API resources to the application
assign_api_resources() {
    local app_id=$1

    # Read each resource from the output file and assign it to the application
    while IFS= read -r resource; do
        echo "Assigning resource to application $app_id: $resource"
        
        # Construct the URL for assigning APIs
        assign_url=$(printf "$BASE_URL_ASSIGN_APIS" "$app_id")

        # Make the API request to assign the resource
        assign_response=$(curl --location --insecure -s "$assign_url" \
            -H "Authorization: Basic $AUTH" \
            -H 'Content-Type: application/json' \
            --data-raw "$resource")

        # Log the response for debugging
        echo "Response from assigning API resource:"
        echo "$assign_response"
    done < "$OUTPUT_FILE"
}

# Step 1: Create the application
create_application

# Step 2: Get the application ID
get_application_id

# Step 3: Start fetching the resources from the Parent Tenant API resources.
fetch_api_resources "$BASE_URL_API_RESOURCES" "$app_id"

# Step 4: Assign the fetched API resources to the application
if [[ -f app_id.txt ]]; then
    app_id=$(<app_id.txt)  # Read the application ID from the saved file
    # assign_api_resources "$app_id"
else
    echo "Application ID file not found. Cannot assign API resources."
    exit 1
fi

echo "API resources have been assigned to the application."
