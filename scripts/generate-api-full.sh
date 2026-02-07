#!/bin/bash
# Generate full TypeScript API clients for all Go-Tangra modules
#
# This script uses openapi-typescript-codegen to generate complete
# typed API clients from OpenAPI specifications.
#
# Usage:
#   ./scripts/generate-api-full.sh
#
# Prerequisites:
#   npm install -g openapi-typescript-codegen
#   # Or use npx (no install needed)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TANGRA_DIR="$(dirname "$ROOT_DIR")"

# Output directories
FRONTEND_DIR="$TANGRA_DIR/go-tangra-frontend"
GENERATED_DIR="$FRONTEND_DIR/apps/admin/src/generated/api"

# Module definitions: module_name:repo_path:openapi_path
MODULES=(
    "ipam:go-tangra-ipam:cmd/server/assets/openapi.yaml"
    "lcm:go-tangra-lcm:cmd/server/assets/openapi.yaml"
    "warden:go-tangra-warden:cmd/server/assets/openapi.yaml"
    "deployer:go-tangra-deployer:cmd/server/assets/openapi.yaml"
    "paperless:go-tangra-paperless:cmd/server/assets/openapi.yaml"
)

echo "============================================"
echo "Go-Tangra Full TypeScript API Generation"
echo "============================================"
echo ""

# Generate full API client for a module
generate_module_client() {
    local module_name="$1"
    local repo_name="$2"
    local openapi_path="$3"

    local repo_dir="$TANGRA_DIR/$repo_name"
    local openapi_file="$repo_dir/$openapi_path"
    local output_dir="$GENERATED_DIR/modules/$module_name"

    echo "--------------------------------------------"
    echo "Generating full API client for: $module_name"
    echo "  OpenAPI: $openapi_file"
    echo "  Output:  $output_dir"

    if [ ! -f "$openapi_file" ]; then
        echo "  WARNING: OpenAPI spec not found, skipping"
        return 0
    fi

    # Create output directory
    mkdir -p "$output_dir"

    # Generate using openapi-typescript-codegen
    echo "  Generating with openapi-typescript-codegen..."
    npx openapi-typescript-codegen \
        --input "$openapi_file" \
        --output "$output_dir" \
        --client fetch \
        --name "${module_name^}Api" \
        --useOptions \
        --exportCore true \
        --exportServices true \
        --exportModels true \
        --exportSchemas false 2>/dev/null || {
        echo "  WARNING: openapi-typescript-codegen failed"
        echo "  Falling back to basic generation..."
        return 1
    }

    # Create a wrapper that sets the base URL for dynamic routing
    cat > "$output_dir/index.ts" << EOF
/**
 * ${module_name^} Module API
 *
 * Auto-generated from OpenAPI specification.
 * Uses dynamic module routing: /admin/v1/modules/$module_name/v1/...
 *
 * Usage:
 *   import { ${module_name^}Api } from '@/generated/api/modules/$module_name';
 *
 *   // Configure the API base URL (do this once at app startup)
 *   OpenAPI.BASE = '/admin/v1/modules/$module_name';
 *
 *   // Use the generated services
 *   const result = await SomeService.getSomething();
 */

export * from './core/OpenAPI';
export * from './core/ApiError';
export * from './core/ApiRequestOptions';
export * from './core/ApiResult';
export * from './core/CancelablePromise';

export * from './models';
export * from './services';

// Re-export OpenAPI config for easy base URL configuration
import { OpenAPI } from './core/OpenAPI';

// Set default base URL for this module
OpenAPI.BASE = '/admin/v1/modules/$module_name';

export { OpenAPI };
EOF

    echo "  Done"
}

# Generate portal admin API
generate_portal_api() {
    echo "============================================"
    echo "Generating Portal Admin API"
    echo "============================================"

    PORTAL_DIR="$TANGRA_DIR/go-tangra-portal"

    if [ -f "$PORTAL_DIR/Makefile" ] && grep -q "^ts:" "$PORTAL_DIR/Makefile"; then
        echo "Running 'make ts' in portal..."
        cd "$PORTAL_DIR" && make ts
        echo "Portal API generated successfully"
    else
        echo "WARNING: Could not generate portal API (no make ts target)"
    fi

    echo ""
}

# Generate modules index
generate_modules_index() {
    local modules_dir="$GENERATED_DIR/modules"

    echo "============================================"
    echo "Generating modules index"
    echo "============================================"

    mkdir -p "$modules_dir"

    # Create the main index file
    cat > "$modules_dir/index.ts" << 'EOF'
/**
 * Go-Tangra Module APIs
 *
 * Auto-generated index for all dynamically registered module APIs.
 * Each module is accessible via the dynamic router at:
 *   /admin/v1/modules/{module_id}/v1/...
 *
 * Usage:
 *   import { ipam, lcm, warden, deployer, paperless } from '@/generated/api/modules';
 *
 *   // Use module APIs
 *   const subnets = await ipam.SubnetService.listSubnets();
 */

EOF

    for module_def in "${MODULES[@]}"; do
        IFS=':' read -r module_name repo_name openapi_path <<< "$module_def"

        if [ -d "$modules_dir/$module_name" ]; then
            echo "export * as $module_name from './$module_name';" >> "$modules_dir/index.ts"
        fi
    done

    echo ""
    echo "Modules index generated"
}

# Main execution
main() {
    # Ensure npm/npx is available
    if ! command -v npx &> /dev/null; then
        echo "ERROR: npx is not installed. Please install Node.js."
        exit 1
    fi

    # Ensure output directory exists
    mkdir -p "$GENERATED_DIR"

    # Generate portal API first
    generate_portal_api

    # Generate module APIs
    echo "============================================"
    echo "Generating Module APIs"
    echo "============================================"
    echo ""

    for module_def in "${MODULES[@]}"; do
        IFS=':' read -r module_name repo_name openapi_path <<< "$module_def"
        generate_module_client "$module_name" "$repo_name" "$openapi_path"
    done

    echo ""

    # Generate modules index
    generate_modules_index

    echo ""
    echo "============================================"
    echo "Full API Generation Complete!"
    echo "============================================"
    echo ""
    echo "Generated structure:"
    echo "  $GENERATED_DIR/"
    echo "  ├── admin/           # Portal admin services (from protos)"
    echo "  └── modules/         # Dynamic module APIs (from OpenAPI)"
    echo "      ├── ipam/"
    echo "      ├── lcm/"
    echo "      ├── warden/"
    echo "      ├── deployer/"
    echo "      ├── paperless/"
    echo "      └── index.ts"
    echo ""
}

main "$@"
