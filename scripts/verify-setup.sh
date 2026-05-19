#!/bin/bash
echo "=== Atlas Setup Verification ==="
echo

REQUIRED_TOOLS=(docker kubectl kind helm terraform aws jq k9s k6 yq stern kustomize argocd mkcert)
MISSING=()

for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &> /dev/null; then
    echo "✓ $tool"
  else
    echo "✗ $tool — MISSING"
    MISSING+=("$tool")
  fi
done

echo
echo "=== Colima Status ==="
colima status 2>&1 | head -5

echo
echo "=== Resource Check (need 4 CPU / 8GB minimum) ==="
docker info 2>/dev/null | grep -E "CPUs|Total Memory"

echo
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "✅ All tools installed. Ready for Atlas Week 1."
else
  echo "❌ Missing: ${MISSING[*]}"
  echo "Install with: brew install ${MISSING[*]}"
fi
