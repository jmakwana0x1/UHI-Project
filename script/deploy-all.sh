#!/usr/bin/env bash
# CrossHedge end-to-end testnet deployment.
#
# Sequences: predict → deploy Lasna RSCs → deploy Unichain origin → deploy Base origin.
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY   - hex key (with 0x prefix), funded on all 3 chains
#   LASNA_RPC              - default: https://lasna-rpc.rnk.dev/
#   UNICHAIN_SEPOLIA_RPC   - default: https://sepolia.unichain.org
#   BASE_SEPOLIA_RPC       - default: https://sepolia.base.org
#
# Optional:
#   SKIP_BASE=1   - skip Base Sepolia deployment (single-origin demo)
#   DRY_RUN=1     - run without --broadcast (for validation)

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev/}"
UNICHAIN_SEPOLIA_RPC="${UNICHAIN_SEPOLIA_RPC:-https://sepolia.unichain.org}"
BASE_SEPOLIA_RPC="${BASE_SEPOLIA_RPC:-https://sepolia.base.org}"
SKIP_BASE="${SKIP_BASE:-0}"
SKIP_LASNA="${SKIP_LASNA:-0}"
DRY_RUN="${DRY_RUN:-0}"

# ─── Pre-flight ──────────────────────────────────────────────────────────
if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    echo "ERROR: DEPLOYER_PRIVATE_KEY env var not set"
    exit 1
fi

# Compute deployer address from private key (using forge's cast tool)
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
echo "==========================================================="
echo "  CrossHedge end-to-end deployment"
echo "==========================================================="
echo "  Deployer:           $DEPLOYER_ADDRESS"
echo "  Lasna RPC:          $LASNA_RPC"
echo "  Unichain RPC:       $UNICHAIN_SEPOLIA_RPC"
[ "$SKIP_BASE" = "0" ] && echo "  Base RPC:           $BASE_SEPOLIA_RPC"
echo "  Dry-run:            $DRY_RUN"
echo "==========================================================="

# Flags for broadcast vs dry-run
BROADCAST_FLAG=""
if [ "$DRY_RUN" = "0" ]; then
    BROADCAST_FLAG="--broadcast"
fi

# ─── Balance preflight ──────────────────────────────────────────────────
# Catch under-funded wallets BEFORE wasting cycles on deploys
echo ""
echo "▶ Pre-flight: checking deployer balances"
echo "---"

MIN_LASNA_WEI=2000000000000000000   # 2 REACT (deploys + 3x RSC funding has slack)
MIN_ORIGIN_WEI=20000000000000000    # 0.02 ETH (5 contract deploys per chain)

if [ "$SKIP_LASNA" = "0" ]; then
    LASNA_BAL=$(cast balance $DEPLOYER_ADDRESS --rpc-url $LASNA_RPC 2>/dev/null || echo 0)
    echo "  Lasna:           $LASNA_BAL wei ($(echo "scale=4; $LASNA_BAL / 1000000000000000000" | bc) REACT)"
    if [ "$LASNA_BAL" -lt "$MIN_LASNA_WEI" ]; then
        echo "  ERROR: Lasna balance below 2 REACT minimum"
        echo "  Bridge more via: cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \\"
        echo "      --rpc-url \$SEPOLIA_RPC --private-key \$DEPLOYER_PRIVATE_KEY \\"
        echo "      \"request(address)\" $DEPLOYER_ADDRESS --value 0.05ether"
        exit 1
    fi
else
    echo "  Lasna:           SKIPPED (SKIP_LASNA=1)"
fi

UNI_BAL=$(cast balance $DEPLOYER_ADDRESS --rpc-url $UNICHAIN_SEPOLIA_RPC 2>/dev/null || echo 0)
echo "  Unichain Sepolia: $UNI_BAL wei ($(echo "scale=4; $UNI_BAL / 1000000000000000000" | bc) ETH)"
if [ "$UNI_BAL" -lt "$MIN_ORIGIN_WEI" ]; then
    echo "  ERROR: Unichain Sepolia balance below 0.02 ETH minimum"
    echo "  Get from: https://faucet.quicknode.com/unichain/sepolia"
    exit 1
fi

if [ "$SKIP_BASE" = "0" ]; then
    BASE_BAL=$(cast balance $DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC 2>/dev/null || echo 0)
    echo "  Base Sepolia:    $BASE_BAL wei ($(echo "scale=4; $BASE_BAL / 1000000000000000000" | bc) ETH)"
    if [ "$BASE_BAL" -lt "$MIN_ORIGIN_WEI" ]; then
        echo "  ERROR: Base Sepolia balance below 0.02 ETH minimum"
        echo "  Get from: https://www.alchemy.com/faucets/base-sepolia"
        exit 1
    fi
fi

echo "  ✓ All balances sufficient"

# ─── Step 1: Predict addresses ───────────────────────────────────────────
echo ""
echo "▶ Step 1/4: Predict deployment addresses"
echo "---"
forge script script/PredictAddresses.s.sol \
    --sig "run(address)" "$DEPLOYER_ADDRESS"

if [ ! -f deployments/predictions.json ]; then
    echo "ERROR: deployments/predictions.json not generated"
    exit 1
fi
echo "✓ predictions.json written"

# ─── Step 2: Deploy reactive (Lasna) ────────────────────────────────────
if [ "$SKIP_LASNA" = "0" ]; then
    echo ""
    echo "▶ Step 2/4: Deploy reactive components on Lasna"
    echo "---"
    forge script script/DeployReactive.s.sol \
        --rpc-url "$LASNA_RPC" \
        $BROADCAST_FLAG

    if [ "$DRY_RUN" = "0" ] && [ ! -f deployments/lasna.json ]; then
        echo "ERROR: deployments/lasna.json not generated"
        exit 1
    fi
    echo "✓ Lasna RSCs deployed"
else
    echo ""
    echo "▶ Step 2/4: Skipped (SKIP_LASNA=1)"
    echo "   Using predictions.json for Lasna RSC addresses."
    echo "   Origin contracts will reference PREDICTED RSC addresses;"
    echo "   they will not receive callbacks until RSCs deploy."
fi

# Post-deploy: fund each RSC with REACT for callback gas
if [ "$DRY_RUN" = "0" ] && [ "$SKIP_LASNA" = "0" ]; then
    echo ""
    echo "▶ Funding RSCs with REACT (1 REACT each)..."
    MATCHING_RSC=$(jq -r '.matchingRsc' deployments/lasna.json)
    STRATEGY_UNI=$(jq -r '.strategyRscUnichain' deployments/lasna.json)
    STRATEGY_BASE=$(jq -r '.strategyRscBase' deployments/lasna.json)

    for RSC in "$MATCHING_RSC" "$STRATEGY_UNI" "$STRATEGY_BASE"; do
        echo "  Funding $RSC..."
        cast send "$RSC" \
            --value 1ether \
            --rpc-url "$LASNA_RPC" \
            --private-key "$DEPLOYER_PRIVATE_KEY" > /dev/null
    done
    echo "✓ All 3 RSCs funded with 1 REACT each"
fi

# ─── Step 3: Deploy origin on Unichain Sepolia ──────────────────────────
echo ""
echo "▶ Step 3/4: Deploy origin contracts on Unichain Sepolia"
echo "---"
forge script script/DeployOrigin.s.sol \
    --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
    $BROADCAST_FLAG

if [ "$DRY_RUN" = "0" ] && [ ! -f deployments/1301.json ]; then
    echo "ERROR: deployments/1301.json not generated"
    exit 1
fi
echo "✓ Unichain Sepolia deployment complete"

# ─── Step 4: Deploy origin on Base Sepolia (optional) ───────────────────
if [ "$SKIP_BASE" = "0" ]; then
    echo ""
    echo "▶ Step 4/4: Deploy origin contracts on Base Sepolia"
    echo "---"
    forge script script/DeployOrigin.s.sol \
        --rpc-url "$BASE_SEPOLIA_RPC" \
        $BROADCAST_FLAG

    if [ "$DRY_RUN" = "0" ] && [ ! -f deployments/84532.json ]; then
        echo "ERROR: deployments/84532.json not generated"
        exit 1
    fi
    echo "✓ Base Sepolia deployment complete"
else
    echo ""
    echo "▶ Step 4/4: Skipped (SKIP_BASE=1)"
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "==========================================================="
echo "  Deployment complete!"
echo "==========================================================="

if [ "$DRY_RUN" = "0" ]; then
    echo ""
    echo "Deployed artifacts:"
    ls -la deployments/*.json | grep -v '\.gitkeep'
    echo ""
    echo "Lasna addresses:"
    jq -r '"  MatchingRSC:        \(.matchingRsc)\n  StrategyRSC_unichain:\(.strategyRscUnichain)\n  StrategyRSC_base:    \(.strategyRscBase)"' deployments/lasna.json 2>/dev/null || echo "  (lasna.json not found)"
    echo ""
    echo "Unichain Sepolia addresses:"
    jq -r '"  USDC:    \(.usdc)\n  Vault:   \(.vault)\n  Hook:    \(.hook)"' deployments/1301.json 2>/dev/null || echo "  (1301.json not found)"
    if [ "$SKIP_BASE" = "0" ]; then
        echo ""
        echo "Base Sepolia addresses:"
        jq -r '"  USDC:    \(.usdc)\n  Vault:   \(.vault)\n  Hook:    \(.hook)"' deployments/84532.json 2>/dev/null || echo "  (84532.json not found)"
    fi
fi
