#!/bin/bash
# Generate TypeScript API clients for all Go-Tangra modules
#
# This script generates TypeScript types and API clients from:
# 1. Portal admin protos (using buf/protoc)
# 2. Module OpenAPI specs (using openapi-typescript)
#
# Usage:
#   ./scripts/generate-api.sh
#
# Prerequisites:
#   - Node.js and npm installed
#   - buf CLI installed (for proto generation)
#   - openapi-typescript installed: npm install -g openapi-typescript

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
echo "Go-Tangra TypeScript API Generation"
echo "============================================"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."

    if ! command -v npm &> /dev/null; then
        echo "ERROR: npm is not installed"
        exit 1
    fi

    if ! command -v npx &> /dev/null; then
        echo "ERROR: npx is not installed"
        exit 1
    fi

    echo "Prerequisites OK"
    echo ""
}

# Generate TypeScript for portal admin services (from protos)
generate_portal_api() {
    echo "============================================"
    echo "Generating Portal Admin API (from protos)"
    echo "============================================"

    PORTAL_DIR="$TANGRA_DIR/go-tangra-portal"

    if [ ! -d "$PORTAL_DIR/api" ]; then
        echo "WARNING: Portal api directory not found at $PORTAL_DIR/api"
        return 1
    fi

    cd "$PORTAL_DIR"

    if [ -f "Makefile" ] && grep -q "^ts:" Makefile; then
        echo "Running 'make ts' in portal..."
        make ts
        echo "Portal API generated successfully"
    else
        echo "WARNING: No 'make ts' target found in portal"

        # Fallback: try buf directly
        if command -v buf &> /dev/null && [ -f "api/buf.admin.typescript.gen.yaml" ]; then
            echo "Running buf generate directly..."
            cd api && buf generate --template buf.admin.typescript.gen.yaml
            echo "Portal API generated successfully"
        else
            echo "WARNING: Could not generate portal API"
        fi
    fi

    echo ""
}

# Generate TypeScript for a module from OpenAPI spec
generate_module_api() {
    local module_name="$1"
    local repo_name="$2"
    local openapi_path="$3"

    local repo_dir="$TANGRA_DIR/$repo_name"
    local openapi_file="$repo_dir/$openapi_path"
    local output_dir="$GENERATED_DIR/modules/$module_name"

    echo "--------------------------------------------"
    echo "Generating API for module: $module_name"
    echo "  OpenAPI: $openapi_file"
    echo "  Output:  $output_dir"

    if [ ! -f "$openapi_file" ]; then
        echo "  WARNING: OpenAPI spec not found, skipping"
        return 0
    fi

    # Create output directory
    mkdir -p "$output_dir"

    # Generate TypeScript types using openapi-typescript
    echo "  Generating TypeScript types..."
    npx openapi-typescript "$openapi_file" -o "$output_dir/types.ts" 2>/dev/null || {
        echo "  WARNING: Failed to generate types with openapi-typescript"
        echo "  Trying alternative approach..."

        # Fallback: generate a basic types file
        generate_basic_types "$module_name" "$openapi_file" "$output_dir"
    }

    # Generate API client
    echo "  Generating API client..."
    generate_api_client "$module_name" "$output_dir"

    echo "  Done"
}

# Generate basic TypeScript types from OpenAPI (fallback)
generate_basic_types() {
    local module_name="$1"
    local openapi_file="$2"
    local output_dir="$3"

    cat > "$output_dir/types.ts" << EOF
/**
 * Auto-generated TypeScript types for $module_name module
 * Generated from: $openapi_file
 *
 * Note: For full type generation, install openapi-typescript:
 *   npm install -g openapi-typescript
 */

// Re-export from OpenAPI spec when available
export interface ApiResponse<T = unknown> {
  code?: number;
  message?: string;
  data?: T;
}

export interface PaginatedResponse<T = unknown> extends ApiResponse<T[]> {
  total?: number;
  page?: number;
  pageSize?: number;
}

// Module-specific types will be generated here
// Run 'npm install -g openapi-typescript && ./scripts/generate-api.sh' for full types
EOF
}

# Generate API client for a module
generate_api_client() {
    local module_name="$1"
    local output_dir="$2"

    cat > "$output_dir/client.ts" << EOF
/**
 * Auto-generated API client for $module_name module
 *
 * This client uses the dynamic module routing:
 *   /admin/v1/modules/$module_name/v1/...
 */

const MODULE_BASE_URL = '/admin/v1/modules/$module_name/v1';

export interface RequestOptions {
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  options?: RequestOptions
): Promise<T> {
  const url = \`\${MODULE_BASE_URL}\${path}\`;

  const response = await fetch(url, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: options?.signal,
  });

  if (!response.ok) {
    throw new Error(\`HTTP error! status: \${response.status}\`);
  }

  return response.json();
}

export const ${module_name}Api = {
  get: <T>(path: string, options?: RequestOptions) =>
    request<T>('GET', path, undefined, options),

  post: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('POST', path, body, options),

  put: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('PUT', path, body, options),

  patch: <T>(path: string, body?: unknown, options?: RequestOptions) =>
    request<T>('PATCH', path, body, options),

  delete: <T>(path: string, options?: RequestOptions) =>
    request<T>('DELETE', path, undefined, options),
};

export default ${module_name}Api;
EOF

    # Create index file
    cat > "$output_dir/index.ts" << EOF
/**
 * $module_name module API
 *
 * Usage:
 *   import { ${module_name}Api } from '@/generated/api/modules/$module_name';
 *
 *   const data = await ${module_name}Api.get('/resources');
 */

export * from './types';
export * from './client';
export * from './services';
export { default as ${module_name}Api } from './client';
EOF
}

# Generate modules index file
generate_modules_index() {
    local modules_dir="$GENERATED_DIR/modules"

    echo "============================================"
    echo "Generating modules index"
    echo "============================================"

    mkdir -p "$modules_dir"

    cat > "$modules_dir/index.ts" << 'EOF'
/**
 * Module API Clients Index
 *
 * Only API clients are re-exported from here to avoid type conflicts.
 * For services and types, import directly from the specific module:
 *
 * @example
 * // Import API clients
 * import { ipamApi, lcmApi, wardenApi } from '@/generated/api/modules';
 *
 * // Import services from specific modules
 * import { SubnetService } from '@/generated/api/modules/ipam';
 * import { FolderService, SecretService } from '@/generated/api/modules/warden';
 * import { TargetConfigurationService } from '@/generated/api/modules/deployer';
 *
 * // Import types from specific modules
 * import type { components } from '@/generated/api/modules/ipam/types';
 */

// Re-export API clients only (services have duplicate type names across modules)
export { ipamApi } from './ipam/client';
export { lcmApi } from './lcm/client';
export { wardenApi } from './warden/client';
export { deployerApi } from './deployer/client';
export { paperlessApi } from './paperless/client';
EOF

    echo ""
    echo "Modules index generated at $modules_dir/index.ts"
}

# Main execution
main() {
    check_prerequisites

    # Ensure output directory exists
    mkdir -p "$GENERATED_DIR"

    # Generate portal API (admin services)
    generate_portal_api

    # Generate module APIs
    echo "============================================"
    echo "Generating Module APIs (from OpenAPI)"
    echo "============================================"
    echo ""

    for module_def in "${MODULES[@]}"; do
        IFS=':' read -r module_name repo_name openapi_path <<< "$module_def"
        generate_module_api "$module_name" "$repo_name" "$openapi_path"
    done

    echo ""

    # Generate modules index
    generate_modules_index

    echo ""
    echo "============================================"
    echo "API Generation Complete!"
    echo "============================================"
    echo ""
    echo "Generated files:"
    echo "  Portal API: $GENERATED_DIR/admin/"
    echo "  Module APIs: $GENERATED_DIR/modules/"
    echo ""
    echo "Usage in frontend:"
    echo "  // Portal services"
    echo "  import { UserService } from '@/generated/api/admin/service/v1';"
    echo ""
    echo "  // Module APIs"
    echo "  import { ipamApi, lcmApi } from '@/generated/api/modules';"
    echo ""
}

main "$@"
