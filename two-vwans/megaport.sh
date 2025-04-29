#!/bin/bash
  echo "INFO: Authenticating to Megaport API..."
    auth_url=https://auth-m2m.megaport.com/oauth2/token
    auth_json=$(curl -s -u "${API_KEY}:${API_SECRET}" --data-urlencode 'grant_type=client_credentials' -H "Content-Type: application/x-www-form-urlencoded" -X POST "$auth_url")
    megaport_token=$(echo "$auth_json" | jq -r '.access_token')

    if [[ -z $megaport_token ]] || [[ "$megaport_token" == "null" ]]
    then
        echo "ERROR: Authentication failed"
        echo $auth_json | jq
        exit 1
    else
        echo "INFO: Authentication successful, token obtained"
    fi




# === USER CONFIGURATION ===
read -p "Enter your API Key: " API_KEY
read -s -p "Enter your API Secret: " API_SECRET
echo
MCR_SERVICE_ID="fc19b29e"  # You can find this in the Megaport portal

# === API ENDPOINTS ===
BASE_URL="https://api.megaport.com/v2"
AUTH_URL="$BASE_URL/login"
SERVICE_URL="$BASE_URL/networkdesign/service/$MCR_SERVICE_ID"

# === AUTHENTICATE: Get JWT token using key + secret ===
echo "🔐 Authenticating with Megaport API..."
AUTH_STRING="$API_KEY:$API_SECRET"
BASIC_AUTH=$(echo -n "$AUTH_STRING" | base64)

auth_response=$(curl -s -X POST "$AUTH_URL" \
  -H "Authorization: Basic $BASIC_AUTH" \
  -H "Content-Type: application/json")

TOKEN=$(echo "$auth_response" | jq -r '.token')

if [[ "$megaport_token" == "null" || -z "$megaport_token" ]]; then
    echo "❌ Failed to retrieve token. Response:"
    echo "$auth_response"
fi

echo "✅ Authenticated. Token retrieved."

# === GET SERVICE ROUTE DETAILS ===
echo "📡 Fetching BGP route info for MCR service ID: $MCR_SERVICE_ID..."

route_response=$(curl -s -X GET "$SERVICE_URL" \
  -H "Authorization: $megaport_token" \
  -H "Content-Type: application/json")

# === PARSE AND DISPLAY BGP ROUTES AND COMMUNITIES ===
echo "📊 Parsing received routes..."

echo "$route_response" | jq '
{
  serviceName: .name,
  bgpSessions: .vxc | map({
    peerName: .name,
    peerIP: .aEnd?.bgpPeer?.ipAddress,
    receivedRoutes: (.routes // []) | map({
      prefix: .prefix,
      nextHop: .nextHop,
      asPath: .asPath,
      communities: .communities
    })
  })
}
'


route_response=$(curl -s -X GET "$SERVICE_URL" \
  -H "Authorization: $megaport_token" \
  -H "Content-Type: application/json")


curl -s -X GET https://api.megaport.com/v2/product/mcr2/fc19b29e-ea39-40fa-b11a-617fbe7b98fd/diagnostics/routes/bgp?async=true -H "Authorization: $megaport_token" -H "Content-Type: application/json"

curl -s -X GET https://api.megaport.com/v2/product/mcr2/fc19b29e-ea39-40fa-b11a-617fbe7b98fd/diagnostics/routes/operation?operationId=de206df6-cd25-4dfe-be19-75231366d1eb -H "Authorization: $megaport_token" -H "Content-Type: application/json"

{"message":"MCR routes are retrieved successfully","terms":"This data is subject to the Acceptable Use Policy https://www.megaport.com/legal/acceptable-use-policy","data":[{"prefix":"10.100.0.0/24","best":true,"external":true,"med":100,"origin":"incomplete","source":"169.254.116.129","valid":true,"weight":0,"asPath":"16550","localPref":100,"nextHop":{"ip":"169.254.116.129","vxc":{"id":"b623139d-2d24-422b-90b1-424c778cd0f7","name":"gcp"}}},{"prefix":"169.254.116.128/29","best":true,"external":true,"med":0,"origin":"IGP","source":"0.0.0.0","valid":true,"weight":32768,"asPath":"","localPref":100,"nextHop":{"ip":"0.0.0.0","vxc":{"id":"b623139d-2d24-422b-90b1-424c778cd0f7","name":"gcp"}}},{"prefix":"169.254.236.120/30","best":true,"external":true,"med":0,"origin":"IGP","source":"0.0.0.0","valid":true,"weight":32768,"asPath":"","localPref":100,"nextHop":{"ip":"0.0.0.0","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"172.16.1.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"172.16.2.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"172.16.3.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"172.16.4.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"172.100.0.0/16","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"192.168.1.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}},{"prefix":"192.168.2.0/24","best":true,"external":true,"origin":"IGP","source":"169.254.236.122","valid":true,"weight":0,"asPath":"12076","localPref":100,"nextHop":{"ip":"169.254.236.122","vxc":{"id":"d0fbc818-668f-4810-af67-6f86c734cde4","name":"er-two-vwans"}}}]}