#!/bin/bash

GOVERNOR="$1"
DEFCONFIG_DIR="arch/arm64/configs"

if [[ -z "$GOVERNOR" ]]; then
    echo "Error: No governor specified."
    exit 1
fi

echo "Applying CPU governor: $GOVERNOR"

case "$GOVERNOR" in
    performance)
        FIND="CONFIG_CPU_FREQ_DEFAULT_GOV_.*"
        REPLACE="CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y"
        ;;
    energystep)
        FIND="CONFIG_CPU_FREQ_DEFAULT_GOV_.*"
        REPLACE="CONFIG_CPU_FREQ_DEFAULT_GOV_ENERGYSTEP=y"
        ;;
    conservative)
        FIND="CONFIG_CPU_FREQ_DEFAULT_GOV_.*"
        REPLACE="CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y"
        ;;
    *)
        echo "Invalid governor: $GOVERNOR"
        exit 1
esac

# Update all _defconfig files
find "$DEFCONFIG_DIR" -type f -name "*_defconfig" -exec sed -i "s/$FIND/$REPLACE/" {} +

echo "Governor changed to $GOVERNOR"
